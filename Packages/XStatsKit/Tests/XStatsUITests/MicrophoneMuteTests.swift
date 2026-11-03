// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private final class MicrophoneHardware: @unchecked Sendable {
  private let lock = NSLock()
  private var muted: Bool?
  private let writable: Bool
  private let failure: AudioControlError?
  let direction: AudioDirection
  private var writes: [Bool] = []
  private var includedApplications = false
  var requests: [Bool] { lock.withLock { writes } }
  var enumeratedApplications: Bool { lock.withLock { includedApplications } }
  var blockSnapshot = false
  let release = DispatchSemaphore(value: 0)
  let started: AsyncStream<Void>
  private let signal: AsyncStream<Void>.Continuation

  init(
    muted: Bool? = false, writable: Bool = true, failure: AudioControlError? = nil,
    direction: AudioDirection = .input
  ) {
    self.muted = muted
    self.writable = writable
    self.failure = failure
    self.direction = direction
    (started, signal) = AsyncStream<Void>.makeStream()
  }

  func snapshot(_ applications: Bool) -> AudioHardwareSnapshot {
    if blockSnapshot {
      signal.yield(())
      _ = release.wait(timeout: .now() + 5)
    }
    return lock.withLock {
      includedApplications = includedApplications || applications
      let input = AudioDeviceInfo(
        id: 987_654, uid: "test.current.microphone", name: "Current microphone",
        hasInput: direction == .input, hasOutput: direction == .output,
        inputMuted: direction == .input ? muted : nil,
        outputMuted: direction == .output ? muted : nil,
        canSetInputMute: direction == .input && writable,
        canSetOutputMute: direction == .output && writable)
      return AudioHardwareSnapshot(
        devices: [input], outputID: direction == .output ? input.id : nil,
        inputID: direction == .input ? input.id : nil, applications: [])
    }
  }

  func mute(
    _ value: Bool, device: AudioDeviceInfo, direction: AudioDirection,
    cancellation: AudioOperationCancellation
  ) -> AudioControlError? {
    #expect(device.uid == "test.current.microphone")
    #expect(direction == self.direction)
    guard !cancellation.isCancelled else { return .routeChanged }
    return lock.withLock {
      writes.append(value)
      if failure == nil { muted = value }
      return failure
    }
  }

  func client() -> AudioHardwareClient {
    AudioHardwareClient(
      selectDevice: { _, _, _ in
        Issue.record("Must not switch devices")
        return .unsupported
      },
      readSnapshot: { self.snapshot($0) },
      muteDevice: { self.mute($0, device: $1, direction: $2, cancellation: $3) })
  }
}

@MainActor
struct MicrophoneMuteTests {
  @Test(arguments: [AudioDirection.input, .output])
  func missingDeviceReportsUnavailableWithoutOpeningAudioControls(direction: AudioDirection)
    async throws
  {
    let suite = "XStats.MicrophoneMuteTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "audio.lowerVolumeOnHeadphoneDisconnect")
    let hardware = AudioHardwareClient(
      selectDevice: { _, _, _ in nil }, readSnapshot: { _ in .empty })
    let controller = AudioController(defaults: defaults, hardware: hardware)
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    controller.toggleDeviceMute(direction)
    let deadline = ContinuousClock.now + .seconds(5)
    while controller.isWorking, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(controller.error == .unavailable)
    #expect(await hardware.listenerCount() == 0)
    #expect(!controller.appVolumeEnabled)
  }

  @Test func commandCatalogIncludesMicrophoneMute() {
    let commands = AppCommand.catalog(supportsFans: false)
    #expect(
      commands.contains {
        $0.id == "audio.toggleMicrophoneMute" && $0.action == .toggleMicrophoneMute
      })
    let search = CommandBarSearch(commands: commands)
    for query in ["麦克风 静音", "mic mute", "microphone", "unmute"] {
      #expect(search.results(for: query).contains { $0.action == .toggleMicrophoneMute })
    }
  }

  @Test func shortcutIsOptInAndFollowsAudioFeatureWithoutLosingItsBinding() throws {
    let suite = "XStats.MicrophoneMuteTests.hotkey.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.hotKeys[.toggleMicrophoneMute] == nil)
    #expect(HotKeyAction.openCommandBar.carbonID == 12)
    #expect(HotKeyAction.toggleMicrophoneMute.carbonID == 13)
    settings.hotKeys[.toggleMicrophoneMute] = HotKey(
      keyCode: 46, modifiers: [.command, .option], key: "m")
    settings.audioEnabled = true
    #expect(HotKeyAction.toggleMicrophoneMute.isEnabled(in: settings))
    settings.audioEnabled = false
    #expect(!HotKeyAction.toggleMicrophoneMute.isEnabled(in: settings))
    let restored = AppSettings(defaults: defaults)
    #expect(restored.hotKeys[.toggleMicrophoneMute] == settings.hotKeys[.toggleMicrophoneMute])
    settings.audioEnabled = true
    #expect(HotKeyAction.toggleMicrophoneMute.isEnabled(in: settings))
  }

  @Test(arguments: [AudioDirection.input, .output])
  func repeatedHiddenOperationsUseCurrentDeviceAndLeaveNoListeners(direction: AudioDirection)
    async throws
  {
    let suite = "XStats.MicrophoneMuteTests.repeat.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "audio.lowerVolumeOnHeadphoneDisconnect")
    let fixture = MicrophoneHardware(direction: direction)
    let hardware = fixture.client()
    let controller = AudioController(defaults: defaults, hardware: hardware)
    defer { controller.stop() }
    let stale = AudioDeviceInfo(
      id: 987_653, uid: "test.old.microphone", name: "Old microphone", hasInput: true,
      inputMuted: true, canSetInputMute: true)
    controller.showPreview(
      AudioHardwareSnapshot(devices: [stale], outputID: nil, inputID: stale.id, applications: []),
      volumes: [:], outputs: [:])
    controller.disableMixing()
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    for _ in 0..<20 {
      let operation = try #require(controller.toggleDeviceMute(direction))
      await operation.value
      #expect(controller.operationError == nil)
      #expect(!controller.isWorking)
    }
    #expect(fixture.requests == (0..<20).map { $0.isMultiple(of: 2) })
    #expect(!fixture.enumeratedApplications)
    #expect(!controller.appVolumeEnabled)
    #expect(await hardware.listenerCount() == 0)
  }

  @Test(arguments: [false, true], [AudioDirection.input, .output])
  func unsupportedDeviceReportsFailureWithoutWriting(
    unknownState: Bool, direction: AudioDirection
  ) async throws {
    let suite = "XStats.MicrophoneMuteTests.unsupported.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = MicrophoneHardware(
      muted: unknownState ? nil : false, writable: unknownState, direction: direction)
    let controller = AudioController(defaults: defaults, hardware: fixture.client())
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    let operation = try #require(controller.toggleDeviceMute(direction))
    await operation.value
    #expect(controller.operationError == .unsupported)
    #expect(fixture.requests.isEmpty)
  }

  @Test(
    arguments: [AudioControlError.routeChanged, .hardware(-1), .unavailable],
    [AudioDirection.input, .output])
  func failedWriteKeepsTheActualMuteState(failure: AudioControlError, direction: AudioDirection)
    async throws
  {
    let suite = "XStats.MicrophoneMuteTests.failure.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = MicrophoneHardware(failure: failure, direction: direction)
    let controller = AudioController(defaults: defaults, hardware: fixture.client())
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    let operation = try #require(controller.toggleDeviceMute(direction))
    await operation.value
    #expect(controller.operationError == failure)
    let device = fixture.snapshot(false).devices.first
    #expect((direction == .output ? device?.outputMuted : device?.inputMuted) == false)
  }

  @Test(arguments: ["disable", "sleep", "stop"], [AudioDirection.input, .output])
  func pendingReadRejectsDuplicatesAndCancellationPreventsWriting(
    action: String, direction: AudioDirection
  ) async throws {
    let suite = "XStats.MicrophoneMuteTests.cancel.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "audio.lowerVolumeOnHeadphoneDisconnect")
    let fixture = MicrophoneHardware(direction: direction)
    fixture.blockSnapshot = true
    defer { fixture.release.signal() }
    let notifications = NotificationCenter()
    let hardware = fixture.client()
    let controller = AudioController(
      defaults: defaults, hardware: hardware, sleepNotifications: notifications)
    defer { controller.stop() }
    #expect(controller.toggleDeviceMute(direction) == nil)
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    let operation = try #require(controller.toggleDeviceMute(direction))
    for await _ in fixture.started { break }
    #expect(controller.toggleDeviceMute(direction) == nil)
    switch action {
    case "disable": controller.setDemand(enabled: false, visible: false, menuVisible: false)
    case "sleep": notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
    default: controller.stop()
    }
    fixture.release.signal()
    await operation.value
    #expect(fixture.requests.isEmpty)
    #expect(controller.error == nil)
    #expect(!controller.isWorking)
    #expect(await hardware.listenerCount() == 0)
  }
}
