// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AudioControl

private final class DisconnectReadback: @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0
  var count: Int { lock.withLock { reads } }
  func isConnected() -> Bool {
    lock.withLock {
      reads += 1
      return reads < 3
    }
  }
}

struct BluetoothAudioDisconnectTests {
  private let paired = BluetoothAudioDevice(
    address: "AA-BB-CC-DD-EE-FF", name: "Headphones", hasInput: true, hasOutput: true)

  @Test func disconnectionWaitsForTheLinkAndTargetsTheCurrentPairedAddress() async throws {
    let fresh = BluetoothAudioDevice(
      address: "aa:bb:cc:dd:ee:ff", name: "Renamed", hasInput: true, hasOutput: true)
    let readback = DisconnectReadback()
    let client = BluetoothAudioClient(
      readPaired: { [fresh] }, connect: { _ in Issue.record("Must not connect") }, devices: { [] },
      readinessTimeout: .seconds(60), pollInterval: .milliseconds(1),
      disconnect: { #expect($0 == fresh.address) },
      isConnected: { _ in readback.isConnected() })
    try await client.disconnect(paired)
    #expect(readback.count == 3)
  }

  @Test func aSuccessfulNativeRequestWithoutDisconnectionDoesNotReportSuccess() async {
    let client = BluetoothAudioClient(
      readPaired: { [paired] }, connect: { _ in }, devices: { [] },
      readinessTimeout: .milliseconds(5), pollInterval: .milliseconds(1),
      disconnect: { _ in }, isConnected: { _ in true })
    await #expect(throws: AudioControlError.bluetoothDisconnectionFailed) {
      try await client.disconnect(paired)
    }
  }

  @Test func aDisconnectionFailurePreservesTheErrorWithoutPolling() async {
    let client = BluetoothAudioClient(
      readPaired: { [paired] }, connect: { _ in }, devices: { [] },
      disconnect: { _ in throw AudioControlError.bluetoothPermissionRequired },
      isConnected: { _ in
        Issue.record("Failed requests must not poll")
        return true
      })
    await #expect(throws: AudioControlError.bluetoothPermissionRequired) {
      try await client.disconnect(paired)
    }
  }

  @Test(arguments: [true, false])
  func staleOrNonOutputDevicesCannotBeDisconnected(stillPaired: Bool) async {
    let inputOnly = BluetoothAudioDevice(
      address: paired.address, name: paired.name, hasInput: true, hasOutput: false)
    let client = BluetoothAudioClient(
      readPaired: { stillPaired ? [inputOnly] : [] }, connect: { _ in }, devices: { [] },
      disconnect: { _ in Issue.record("An invalid target must not be disconnected") },
      isConnected: { _ in
        Issue.record("An invalid target must not be polled")
        return true
      })
    await #expect(throws: stillPaired ? AudioControlError.unsupported : .routeChanged) {
      try await client.disconnect(paired)
    }
  }

  @Test(arguments: [true, false])
  func cancellationRejectsQueuedWritesAndLateNativeResults(cancelDuringCatalog: Bool) async {
    let (started, signal) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let client = BluetoothAudioClient(
      readPaired: {
        if cancelDuringCatalog {
          signal.yield(())
          signal.finish()
          _ = release.wait(timeout: .now() + 60)
        }
        return [paired]
      }, connect: { _ in }, devices: { [] },
      disconnect: { _ in
        if cancelDuringCatalog { Issue.record("Cancelled request reached the native write") }
        signal.yield(())
        signal.finish()
        _ = release.wait(timeout: .now() + 60)
      },
      isConnected: { _ in
        Issue.record("Cancelled result reached readback")
        return false
      })
    let task = Task { try await client.disconnect(paired) }
    for await _ in started { break }
    task.cancel()
    release.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
