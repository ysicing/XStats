// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private final class OutputShortcutHardware: @unchecked Sendable {
  private let lock = NSLock()
  let devices: [AudioDeviceInfo]
  private var outputID: UInt32?
  private var selections: [UInt32] = []
  private var includedApplications = false
  let failure: AudioControlError?
  let blocksSnapshot: Bool
  let release = DispatchSemaphore(value: 0)
  let started: AsyncStream<Void>
  private let signal: AsyncStream<Void>.Continuation

  init(
    devices: [AudioDeviceInfo], outputID: UInt32? = 1, failure: AudioControlError? = nil,
    blocksSnapshot: Bool = false
  ) {
    self.devices = devices
    self.outputID = outputID
    self.failure = failure
    self.blocksSnapshot = blocksSnapshot
    (started, signal) = AsyncStream<Void>.makeStream()
  }

  var requests: [UInt32] { lock.withLock { selections } }
  var enumeratedApplications: Bool { lock.withLock { includedApplications } }

  func snapshot(_ applications: Bool) -> AudioHardwareSnapshot {
    if blocksSnapshot {
      signal.yield(())
      _ = release.wait(timeout: .now() + 5)
    }
    return lock.withLock {
      includedApplications = includedApplications || applications
      return AudioHardwareSnapshot(
        devices: devices, outputID: outputID, inputID: nil, applications: [])
    }
  }

  func client() -> AudioHardwareClient {
    AudioHardwareClient(
      selectDevice: { device, direction, cancellation in
        #expect(direction == .output)
        guard !cancellation.isCancelled else { return .routeChanged }
        return self.lock.withLock {
          self.selections.append(device.id)
          if self.failure == nil { self.outputID = device.id }
          return self.failure
        }
      },
      readSnapshot: { self.snapshot($0) })
  }
}

@MainActor
struct AudioOutputShortcutTests {
  private let devices = [
    AudioDeviceInfo(id: 1, uid: "test.a", name: "A", hasOutput: true),
    AudioDeviceInfo(id: 9, uid: "test.input", name: "Input", hasInput: true),
    AudioDeviceInfo(
      id: 8, uid: "test.unsupported", name: "Unsupported", hasOutput: true,
      canBeDefaultOutput: false),
    AudioDeviceInfo(id: 2, uid: "test.b", name: "B", hasOutput: true),
    AudioDeviceInfo(id: 3, uid: "test.c", name: "C", hasOutput: true),
  ]

  @Test func catalogAndShortcutFollowTheAudioFeature() throws {
    let commands = AppCommand.catalog(supportsFans: false)
    let search = CommandBarSearch(commands: commands)
    for query in ["下一个 音频 输出", "next audio output", "speaker"] {
      #expect(search.results(for: query).contains { $0.action == .nextAudioOutput })
    }
    let suite = "XStats.AudioOutputShortcutTests.hotkey.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.hotKeys[.nextAudioOutput] == nil)
    #expect(HotKeyAction.toggleMicrophoneMute.carbonID == 13)
    #expect(HotKeyAction.nextAudioOutput.carbonID == 14)
    settings.hotKeys[.nextAudioOutput] = HotKey(
      keyCode: 31, modifiers: [.command, .option], key: "o")
    settings.audioEnabled = true
    #expect(HotKeyAction.nextAudioOutput.isEnabled(in: settings))
    settings.audioEnabled = false
    #expect(!HotKeyAction.nextAudioOutput.isEnabled(in: settings))
    let restored = AppSettings(defaults: defaults)
    #expect(restored.hotKeys[.nextAudioOutput] == settings.hotKeys[.nextAudioOutput])
  }

  @Test func hiddenOperationsCycleFreshAvailableOutputsWithoutListeners() async throws {
    let suite = "XStats.AudioOutputShortcutTests.repeat.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = OutputShortcutHardware(devices: devices)
    let hardware = fixture.client()
    let controller = AudioController(defaults: defaults, hardware: hardware)
    defer { controller.stop() }
    controller.showPreview(
      AudioHardwareSnapshot(devices: [devices[4]], outputID: 3, inputID: nil, applications: []),
      volumes: [:], outputs: [:])
    controller.disableMixing()
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    for _ in 0..<12 {
      let operation = try #require(controller.selectNextOutput())
      await operation.value
      #expect(controller.operationError == nil)
      #expect(!controller.isWorking)
    }
    #expect(fixture.requests == Array(repeating: [UInt32(2), 3, 1], count: 4).flatMap { $0 })
    #expect(!fixture.enumeratedApplications)
    #expect(!controller.appVolumeEnabled)
    #expect(await hardware.listenerCount() == 0)
  }

  @Test(arguments: [UInt32(1), 99])
  func aSingleAvailableOutputIsSelectedOnlyWhenItIsNotCurrent(currentID: UInt32) async throws {
    let suite = "XStats.AudioOutputShortcutTests.single.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = OutputShortcutHardware(devices: Array(devices.prefix(3)), outputID: currentID)
    let controller = AudioController(defaults: defaults, hardware: fixture.client())
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    let operation = try #require(controller.selectNextOutput())
    await operation.value
    #expect(controller.operationError == nil)
    #expect(fixture.requests == (currentID == 1 ? [] : [1]))
  }

  @Test func noAvailableOutputsReportsUnavailableWithoutWriting() async throws {
    let suite = "XStats.AudioOutputShortcutTests.empty.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = OutputShortcutHardware(devices: Array(devices[1...2]), outputID: nil)
    let controller = AudioController(defaults: defaults, hardware: fixture.client())
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    let operation = try #require(controller.selectNextOutput())
    await operation.value
    #expect(controller.operationError == .unavailable)
    #expect(fixture.requests.isEmpty)
  }

  @Test(arguments: [AudioControlError.routeChanged, .hardware(-1)])
  func selectionFailureKeepsTheCurrentOutput(failure: AudioControlError) async throws {
    let suite = "XStats.AudioOutputShortcutTests.failure.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = OutputShortcutHardware(devices: devices, failure: failure)
    let controller = AudioController(defaults: defaults, hardware: fixture.client())
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    let operation = try #require(controller.selectNextOutput())
    await operation.value
    #expect(controller.operationError == failure)
    #expect(fixture.snapshot(false).outputID == 1)
  }

  @Test(arguments: ["disable", "sleep", "stop"])
  func cancellationDuringTheReadPreventsSelectionAndRejectsDuplicates(action: String) async throws {
    let suite = "XStats.AudioOutputShortcutTests.cancel.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fixture = OutputShortcutHardware(devices: devices, blocksSnapshot: true)
    defer { fixture.release.signal() }
    let notifications = NotificationCenter()
    let hardware = fixture.client()
    let controller = AudioController(
      defaults: defaults, hardware: hardware, sleepNotifications: notifications)
    defer { controller.stop() }
    #expect(controller.selectNextOutput() == nil)
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    let operation = try #require(controller.selectNextOutput())
    for await _ in fixture.started { break }
    #expect(controller.selectNextOutput() == nil)
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
