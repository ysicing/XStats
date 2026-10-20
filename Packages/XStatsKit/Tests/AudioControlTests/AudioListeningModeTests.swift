// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreAudio
import Foundation
import Testing
@testable import AudioControl

private final class ListeningModeProbe: @unchecked Sendable {
  let device = AudioDeviceInfo(
    id: 123_456, uid: "test.airpods", name: "Headphones", hasOutput: true,
    bluetoothAddress: "AA:BB:CC:DD:EE:FF")
  let lock = NSLock()
  var current = AudioListeningMode.noiseCancellation
  var modes: [AudioListeningMode] = [.noiseCancellation, .transparency, .adaptive]
  var writable = true
  var available = true
  var confirms = true
  var writes = 0
  var reads = 0
  var additions = 0
  var removals = 0
  var target: AudioListeningMode?
  var blocked = false
  let release = DispatchSemaphore(value: 0)
  let started: AsyncStream<Void>
  private let signal: AsyncStream<Void>.Continuation

  init() { (started, signal) = AsyncStream<Void>.makeStream() }

  func read(_ device: AudioDeviceInfo) -> AudioListeningModeState? {
    let shouldBlock = lock.withLock { blocked }
    if shouldBlock {
      signal.yield(())
      signal.finish()
      _ = release.wait(timeout: .now() + 60)
    }
    return lock.withLock {
      reads += 1
      guard available, device.uid == self.device.uid, device.id == self.device.id else {
        return nil
      }
      if confirms, let target, reads >= 4 { current = target }
      return AudioListeningModeState(modes: modes, current: current, canSet: writable)
    }
  }

  func client() -> AudioListeningModeClient {
    AudioListeningModeClient(
      read: { self.read($0) },
      write: { _, mode in
        self.lock.withLock {
          self.writes += 1
          self.target = mode
        }
      },
      confirmationDelay: .milliseconds(2),
      add: { _, _, _, _ in
        self.lock.withLock { self.additions += 1 }
        return true
      },
      remove: { _, _, _, _ in self.lock.withLock { self.removals += 1 } })
  }
}

struct AudioListeningModeTests {
  @Test func supportMaskAndUnknownCurrentValuesNeverInventModes() {
    #expect(AudioListeningMode.supported(by: 0).isEmpty)
    #expect(AudioListeningMode.supported(by: 1) == [.noiseCancellation])
    #expect(
      AudioListeningMode.supported(by: 0xFFFF_FFFF) == [
        .noiseCancellation, .transparency, .adaptive,
      ])
    #expect(AudioListeningMode(rawValue: 0) == nil)
    #expect(AudioListeningMode(rawValue: 99) == nil)
    #expect(AudioListeningMode(rawValue: 1) == .off)
  }

  @Test func delayedConfirmationWritesOnlyOnceAndKeepsReading() async throws {
    let probe = ListeningModeProbe()
    let client = probe.client()
    try await client.setMode(.transparency, device: probe.device)
    #expect(probe.lock.withLock { probe.writes } == 1)
    #expect(probe.lock.withLock { probe.current } == .transparency)
    #expect(probe.lock.withLock { probe.reads } >= 4)
  }

  @Test func setterAcceptanceWithoutReadbackIsAnExplicitFailure() async {
    let probe = ListeningModeProbe()
    probe.confirms = false
    let client = probe.client()
    await #expect(throws: AudioControlError.listeningModeUnconfirmed) {
      try await client.setMode(.adaptive, device: probe.device)
    }
    #expect(probe.lock.withLock { probe.writes } == 1)
    #expect(probe.lock.withLock { probe.current } == .noiseCancellation)
  }

  @Test func aDeviceDisappearingAfterTheWriteFailsWithoutRetrying() async {
    let probe = ListeningModeProbe()
    let client = AudioListeningModeClient(
      read: { probe.read($0) },
      write: { _, _ in
        probe.lock.withLock {
          probe.writes += 1
          probe.available = false
        }
      },
      confirmationDelay: .milliseconds(1))
    await #expect(throws: AudioControlError.routeChanged) {
      try await client.setMode(.transparency, device: probe.device)
    }
    #expect(probe.lock.withLock { probe.writes } == 1)
  }

  @Test func nativeSetterErrorsPropagateWithoutReadbackOrRetry() async {
    let probe = ListeningModeProbe()
    let client = AudioListeningModeClient(
      read: { probe.read($0) }, write: { _, _ in throw AudioControlError.hardware(-1) })
    await #expect(throws: AudioControlError.hardware(-1)) {
      try await client.setMode(.transparency, device: probe.device)
    }
    #expect(probe.lock.withLock { probe.reads } == 1)
  }

  @Test func releasingTheClientRemovesItsListeners() async {
    let probe = ListeningModeProbe()
    var client: AudioListeningModeClient? = probe.client()
    _ = await client?.watch(probe.device, onChange: {})
    #expect(await client?.listenerCount() == 2)
    client = nil
    #expect(probe.lock.withLock { probe.removals } == 2)
  }

  @Test(arguments: ["readOnly", "singleMode", "unsupported", "gone", "off"])
  func unsupportedOrStaleTargetsDoNotWrite(reason: String) async {
    let probe = ListeningModeProbe()
    if reason == "readOnly" { probe.writable = false }
    if reason == "singleMode" { probe.modes = [.noiseCancellation] }
    if reason == "unsupported" { probe.modes = [.noiseCancellation, .transparency] }
    if reason == "gone" { probe.available = false }
    let client = probe.client()
    await #expect(throws: reason == "gone" ? AudioControlError.routeChanged : .unsupported) {
      try await client.setMode(reason == "off" ? .off : .adaptive, device: probe.device)
    }
    #expect(probe.lock.withLock { probe.writes } == 0)
  }

  @Test func cancellationWhileQueuedPreventsTheWrite() async throws {
    let probe = ListeningModeProbe()
    probe.blocked = true
    defer { probe.release.signal() }
    let client = probe.client()
    let task = Task { try await client.setMode(.adaptive, device: probe.device) }
    for await _ in probe.started { break }
    task.cancel()
    probe.release.signal()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(probe.lock.withLock { probe.writes } == 0)
  }

  @Test func repeatedVisibilityAndDeviceChangesReleaseAllListeners() async {
    let probe = ListeningModeProbe()
    let client = probe.client()
    for _ in 0..<10 {
      #expect(await client.watch(probe.device, onChange: {}) != nil)
      _ = await client.watch(probe.device, onChange: {})
      #expect(await client.listenerCount() == 2)
      client.stopWatching()
      #expect(await client.listenerCount() == 0)
    }
    #expect(probe.lock.withLock { probe.additions } == 20)
    #expect(probe.lock.withLock { probe.removals } == 20)
    _ = await client.watch(probe.device, onChange: {})
    #expect(await client.watch(nil, onChange: {}) == nil)
    #expect(await client.listenerCount() == 0)
  }

  @Test func realReadOnlyProbeDoesNotExposeControlsForUnrelatedDevices() async {
    let hardware = AudioHardwareClient()
    let snapshot = await hardware.snapshot(includeApplications: false)
    let client = AudioListeningModeClient()
    for device in snapshot.devices where device.bluetoothAddress == nil {
      #expect(await client.watch(device, onChange: {}) == nil)
    }
    client.stopWatching()
    #expect(await client.listenerCount() == 0)
  }
}
