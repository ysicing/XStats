// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AudioControl
@testable import XStatsUI

private final class PendingListeningModeWrite: @unchecked Sendable {
  private let lock = NSLock()
  private var writes = 0
  let release = DispatchSemaphore(value: 0)
  let started: AsyncStream<Void>
  private let signal: AsyncStream<Void>.Continuation
  var count: Int { lock.withLock { writes } }
  init() { (started, signal) = AsyncStream<Void>.makeStream() }

  func write() throws {
    lock.withLock { writes += 1 }
    signal.yield(())
    signal.finish()
    _ = release.wait(timeout: .now() + 60)
    throw AudioControlError.listeningModeUnconfirmed
  }
}

@MainActor
struct AudioListeningModeTests {
  @Test(arguments: ["hidden", "disabled", "paused", "stopped"])
  func droppingVisibleDemandCancelsModeChangesAndRejectsLateErrors(reason: String) async throws {
    let suite = "XStats.AudioListeningModeTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let pending = PendingListeningModeWrite()
    defer { pending.release.signal() }
    let state = AudioListeningModeState(
      modes: [.noiseCancellation, .transparency, .adaptive], current: .noiseCancellation,
      canSet: true)
    let client = AudioListeningModeClient(
      read: { _ in state }, write: { _, _ in try pending.write() })
    let controller = AudioController(defaults: defaults, listeningModes: client)
    defer { controller.stop() }
    let output = AudioDeviceInfo(
      id: 123_456, uid: "test.airpods", name: "Headphones", hasOutput: true,
      bluetoothAddress: "AA:BB:CC:DD:EE:FF")
    controller.showPreview(
      AudioHardwareSnapshot(devices: [output], outputID: output.id, inputID: nil, applications: []),
      volumes: [:], outputs: [:], listeningMode: state)
    controller.setDemand(enabled: true, visible: true, menuVisible: false)
    controller.setListeningMode(.transparency)
    #expect(controller.changingListeningMode == .transparency)
    #expect(controller.isWorking)
    controller.setListeningMode(.adaptive)
    for await _ in pending.started { break }
    #expect(pending.count == 1)
    switch reason {
    case "paused": controller.setPaused(true)
    case "stopped": controller.stop()
    default: controller.setDemand(enabled: reason != "disabled", visible: false, menuVisible: false)
    }
    #expect(!controller.isWorking)
    #expect(controller.changingListeningMode == nil)
    #expect(controller.listeningMode == nil)
    pending.release.signal()
    #expect(await client.listenerCount() == 0)
    await Task.yield()
    #expect(controller.error == nil)
  }

  @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
  func listeningModesFitNarrowLayoutsWithProgress(direction: LayoutDirection) throws {
    _ = NSApplication.shared
    let state = AudioListeningModeState(
      modes: [.noiseCancellation, .transparency, .adaptive], current: .noiseCancellation,
      canSet: true)
    for target: AudioListeningMode? in [nil, .adaptive] {
      let host = NSHostingView(
        rootView: AudioListeningModeControl(
          state: state, target: target, busy: target != nil, select: { _ in }
        )
        .environment(\.layoutDirection, direction).frame(width: 220, alignment: .leading))
      host.frame = NSRect(x: 0, y: 0, width: 220, height: 250)
      host.layoutSubtreeIfNeeded()
      #expect(host.fittingSize.width <= 221)
      #expect(host.fittingSize.height > 20 && host.fittingSize.height < 200)
    }
  }
}
