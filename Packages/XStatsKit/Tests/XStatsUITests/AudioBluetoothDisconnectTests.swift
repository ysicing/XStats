// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private final class PendingBluetoothDisconnection: @unchecked Sendable {
  private let lock = NSLock()
  private var requests = 0
  let release = DispatchSemaphore(value: 0)
  let started: AsyncStream<Void>
  private let signal: AsyncStream<Void>.Continuation
  let failure: Bool
  let paired = BluetoothAudioDevice(
    address: "AA:BB:CC:DD:EE:FF", name: "Headphones", hasInput: true, hasOutput: true)
  var count: Int { lock.withLock { requests } }
  init(failure: Bool = false) {
    self.failure = failure
    (started, signal) = AsyncStream<Void>.makeStream()
  }
  func disconnect() throws {
    lock.withLock { requests += 1 }
    signal.yield(())
    signal.finish()
    _ = release.wait(timeout: .now() + 60)
    if failure { throw AudioControlError.bluetoothDisconnectionFailed }
  }
}

@MainActor
struct AudioBluetoothDisconnectTests {
  private func controller(_ pending: PendingBluetoothDisconnection, defaults: UserDefaults)
    -> (AudioController, BluetoothAudioClient)
  {
    let bluetooth = BluetoothAudioClient(
      readPaired: { [pending.paired] }, connect: { _ in Issue.record("Must not connect") },
      devices: { [] }, disconnect: { _ in try pending.disconnect() }, isConnected: { _ in false })
    let controller = AudioController(defaults: defaults, bluetooth: bluetooth)
    let output = AudioDeviceInfo(
      id: 123_456, uid: "test.bluetooth.output", name: "Headphones", hasInput: true,
      hasOutput: true, bluetoothAddress: pending.paired.address)
    controller.showPreview(
      AudioHardwareSnapshot(
        devices: [output], outputID: output.id, inputID: output.id, applications: []),
      volumes: [:], outputs: [:], bluetoothDevices: [pending.paired])
    // 先注入离屏夹具，再同步发起操作；启用后真实快照会异步替换演示数据。
    controller.setDemand(enabled: true, visible: true, menuVisible: false)
    return (controller, bluetooth)
  }

  @Test(arguments: [false, true])
  func disconnectReportsItsInFlightStateAndFinalResultWithoutDuplicateRequests(failure: Bool)
    async throws
  {
    let suite = "XStats.AudioDisconnectTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let pending = PendingBluetoothDisconnection(failure: failure)
    defer { pending.release.signal() }
    let (controller, _) = controller(pending, defaults: defaults)
    defer { controller.stop() }
    #expect(controller.connectedBluetoothOutput == pending.paired)
    controller.disconnectBluetoothOutput()
    try #require(controller.isWorking)
    #expect(controller.disconnectingBluetooth == pending.paired.id)
    for await _ in pending.started { break }
    controller.disconnectBluetoothOutput()
    #expect(pending.count == 1)
    pending.release.signal()
    let deadline = ContinuousClock.now + .seconds(60)
    while controller.isWorking, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!controller.isWorking)
    #expect(controller.disconnectingBluetooth == nil)
    #expect(controller.error == (failure ? .bluetoothDisconnectionFailed : nil))
  }

  @Test(arguments: ["hidden", "disabled", "paused"])
  func droppingVisibleDemandRejectsALateDisconnectionResult(reason: String) async throws {
    let suite = "XStats.AudioDisconnectCancellationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let pending = PendingBluetoothDisconnection(failure: true)
    defer { pending.release.signal() }
    let (controller, bluetooth) = controller(pending, defaults: defaults)
    defer { controller.stop() }
    controller.disconnectBluetoothOutput()
    try #require(controller.isWorking)
    for await _ in pending.started { break }
    if reason == "paused" {
      controller.setPaused(true)
    } else {
      controller.setDemand(enabled: reason != "disabled", visible: false, menuVisible: false)
    }
    #expect(!controller.isWorking)
    #expect(controller.disconnectingBluetooth == nil)
    pending.release.signal()
    _ = try await bluetooth.pairedDevices()  // 串行屏障，确保原生操作已返回。
    await Task.yield()
    #expect(controller.error == nil)
    #expect(controller.disconnectingBluetooth == nil)
  }

  @Test func sameNamesAndNonBluetoothOutputsNeverExposeTheDisconnectAction() throws {
    let suite = "XStats.AudioDisconnectTargetTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = AudioController(defaults: defaults)
    defer { controller.stop() }
    let paired = BluetoothAudioDevice(
      address: "AA:BB:CC:DD:EE:FF", name: "Headphones", hasInput: true, hasOutput: true)
    for address in [nil, "11:22:33:44:55:66"] as [String?] {
      let output = AudioDeviceInfo(
        id: 1, uid: "test.output", name: paired.name, hasOutput: true, bluetoothAddress: address)
      controller.showPreview(
        AudioHardwareSnapshot(devices: [output], outputID: 1, inputID: nil, applications: []),
        volumes: [:], outputs: [:], bluetoothDevices: [paired])
      #expect(controller.connectedBluetoothOutput == nil)
      controller.disconnectBluetoothOutput()
      #expect(!controller.isWorking)
    }
  }
}
