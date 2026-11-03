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
    AudioDeviceInfo(
      id: 1, uid: "test.a", name: "A", hasOutput: true, outputKind: .speaker, isBuiltIn: true),
    AudioDeviceInfo(id: 9, uid: "test.input", name: "Input", hasInput: true),
    AudioDeviceInfo(
      id: 8, uid: "test.unsupported", name: "Unsupported", hasOutput: true,
      canBeDefaultOutput: false),
    AudioDeviceInfo(id: 2, uid: "test.b", name: "B", hasOutput: true, outputKind: .headphones),
    AudioDeviceInfo(id: 3, uid: "test.c", name: "C", hasOutput: true, outputKind: .headphones),
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

  @Test func outputMuteShortcutIsUnboundAndKeepsExistingCarbonIDs() throws {
    let suite = "XStats.AudioOutputShortcutTests.mute.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.hotKeys[.toggleOutputMute] == nil)
    #expect(HotKeyAction.nextAudioOutput.carbonID == 14)
    #expect(HotKeyAction.toggleOutputMute.carbonID == 15)
    settings.hotKeys[.toggleOutputMute] = HotKey(
      keyCode: 46, modifiers: [.command, .control], key: "m")
    settings.audioEnabled = true
    #expect(HotKeyAction.toggleOutputMute.isEnabled(in: settings))
    settings.audioEnabled = false
    #expect(!HotKeyAction.toggleOutputMute.isEnabled(in: settings))
    #expect(
      AppSettings(defaults: defaults).hotKeys[.toggleOutputMute]
        == settings.hotKeys[.toggleOutputMute])
    let search = CommandBarSearch(commands: AppCommand.catalog(supportsFans: false))
    for query in ["输出 静音", "speaker mute", "headphones unmute"] {
      #expect(search.results(for: query).contains { $0.action == .toggleOutputMute })
    }
  }

  @Test func defaultsExcludeDisplaysAndUnknownDevicesEvenWhenTheyAreCurrent() async throws {
    let suite = "XStats.AudioOutputShortcutTests.defaults.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let display = AudioDeviceInfo(
      id: 15, uid: "test.display", name: "Display", hasOutput: true, outputKind: .display)
    let unknown = AudioDeviceInfo(
      id: 16, uid: "test.unknown", name: "Virtual", hasOutput: true)
    let connected = [display, unknown, devices[0], devices[3]]
    let fixture = OutputShortcutHardware(devices: connected, outputID: display.id)
    let controller = AudioController(defaults: defaults, hardware: fixture.client())
    defer { controller.stop() }
    controller.showPreview(
      AudioHardwareSnapshot(
        devices: connected, outputID: display.id, inputID: nil, applications: []),
      volumes: [:], outputs: [:])
    #expect(!controller.isOutputCycleDeviceSelected(display))
    #expect(!controller.isOutputCycleDeviceSelected(unknown))
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    await controller.selectNextOutput()?.value
    #expect(fixture.requests == [1])
    controller.setOutputCycleDevice(display, included: true)
    #expect(controller.outputCycleDeviceUIDs == ["test.a", "test.b", "test.display"])
    let restored = AudioController(defaults: defaults)
    defer { restored.stop() }
    #expect(restored.isOutputCycleDeviceSelected(display))
    controller.resetOutputCycleDevices()
    #expect(!controller.isOutputCycleDeviceSelected(display))
  }

  @Test func headphoneProtectionPreferenceDefaultsOnAndStopsWithLifecycle() async throws {
    let suite = "XStats.AudioOutputShortcutTests.protection.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let notifications = NotificationCenter()
    let hardware = OutputShortcutHardware(devices: []).client()
    let controller = AudioController(
      defaults: defaults, hardware: hardware, sleepNotifications: notifications)
    defer { controller.stop() }
    #expect(controller.lowerVolumeOnHeadphoneDisconnect)
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    #expect(await hardware.headphoneListenerCount() > 0)
    notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
    #expect(await hardware.headphoneListenerCount() == 0)
    notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(await hardware.headphoneListenerCount() > 0)
    controller.setPaused(true)
    #expect(await hardware.headphoneListenerCount() == 0)
    controller.setPaused(false)
    #expect(await hardware.headphoneListenerCount() > 0)
    controller.setLowerVolumeOnHeadphoneDisconnect(false)
    #expect(await hardware.headphoneListenerCount() == 0)
    let restored = AudioController(defaults: defaults)
    defer { restored.stop() }
    #expect(!restored.lowerVolumeOnHeadphoneDisconnect)
    controller.setLowerVolumeOnHeadphoneDisconnect(true)
    #expect(await hardware.headphoneListenerCount() > 0)
    controller.stop()
    #expect(await hardware.headphoneListenerCount() == 0)
  }

  @Test(arguments: [AudioOutputKind.display, .unknown, .bluetooth, .usb, .speaker])
  func noRecognizedDefaultNeverFallsBackToAllOutputs(kind: AudioOutputKind) async throws {
    let suite = "XStats.AudioOutputShortcutTests.noDefault.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let external = AudioDeviceInfo(
      id: 1, uid: "test.external", name: "External", hasOutput: true, outputKind: kind)
    let fixture = OutputShortcutHardware(devices: [external])
    let controller = AudioController(defaults: defaults, hardware: fixture.client())
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    await controller.selectNextOutput()?.value
    #expect(fixture.requests.isEmpty)
    #expect(controller.operationError == .unavailable)
  }

  @Test func hiddenOperationsCycleFreshAvailableOutputsWithoutListeners() async throws {
    let suite = "XStats.AudioOutputShortcutTests.repeat.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "audio.lowerVolumeOnHeadphoneDisconnect")
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

  @Test func selectedOutputsPersistAndSkipExcludedDevicesWithoutBackgroundDemand() async throws {
    let suite = "XStats.AudioOutputShortcutTests.selection.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "audio.lowerVolumeOnHeadphoneDisconnect")
    let fixture = OutputShortcutHardware(devices: devices)
    let hardware = fixture.client()
    let controller = AudioController(defaults: defaults, hardware: hardware)
    defer { controller.stop() }
    controller.showPreview(
      AudioHardwareSnapshot(devices: devices, outputID: 1, inputID: nil, applications: []),
      volumes: [:], outputs: [:])
    #expect(controller.outputCycleDeviceUIDs == nil)
    controller.setOutputCycleDevice(devices[3], included: false)
    #expect(controller.outputCycleDeviceUIDs == ["test.a", "test.c"])
    controller.setOutputCycleDevice(devices[1], included: true)
    controller.setOutputCycleDevice(devices[2], included: true)
    #expect(controller.outputCycleDeviceUIDs == ["test.a", "test.c"])
    let restored = AudioController(defaults: defaults)
    defer { restored.stop() }
    #expect(restored.outputCycleDeviceUIDs == controller.outputCycleDeviceUIDs)
    #expect(await hardware.listenerCount() == 0)
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    for _ in 0..<4 {
      let operation = try #require(controller.selectNextOutput())
      await operation.value
    }
    #expect(fixture.requests == [3, 1, 3, 1])
    #expect(!fixture.enumeratedApplications)
    #expect(await hardware.listenerCount() == 0)
    controller.resetOutputCycleDevices()
    #expect(controller.outputCycleDeviceUIDs == nil)
    #expect(defaults.object(forKey: "audio.outputCycleDevices") == nil)
    let operation = try #require(controller.selectNextOutput())
    await operation.value
    #expect(fixture.requests.last == 2)
  }

  @Test(arguments: [false, true])
  func explicitSelectionNeverFallsBackToExcludedOutputs(emptySelection: Bool) async throws {
    let suite = "XStats.AudioOutputShortcutTests.disconnected.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let selected = emptySelection ? [] : ["test.disconnected"]
    defaults.set(try JSONEncoder().encode(selected), forKey: "audio.outputCycleDevices")
    let fixture = OutputShortcutHardware(devices: devices)
    let controller = AudioController(defaults: defaults, hardware: fixture.client())
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    let operation = try #require(controller.selectNextOutput())
    await operation.value
    #expect(fixture.requests.isEmpty)
    #expect(controller.operationError == .unavailable)
    #expect(controller.outputCycleDeviceUIDs == Set(selected))
  }

  @Test func deviceSelectionUsesStableUIDRatherThanNameOrHALID() async throws {
    let suite = "XStats.AudioOutputShortcutTests.identity.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
      try JSONEncoder().encode(["test.b", "test.disconnected"]),
      forKey: "audio.outputCycleDevices")
    let reconnected = AudioDeviceInfo(
      id: 42, uid: "test.b", name: "Renamed device", hasOutput: true)
    let impostor = AudioDeviceInfo(id: 2, uid: "test.other", name: "B", hasOutput: true)
    let fixture = OutputShortcutHardware(devices: [devices[0], impostor, reconnected])
    let controller = AudioController(defaults: defaults, hardware: fixture.client())
    defer { controller.stop() }
    controller.setDemand(enabled: true, visible: false, menuVisible: false)
    let operation = try #require(controller.selectNextOutput())
    await operation.value
    #expect(fixture.requests == [42])
    controller.setOutputCycleDevice(reconnected, included: false)
    #expect(controller.outputCycleDeviceUIDs == ["test.disconnected"])
    controller.setDemand(enabled: false, visible: false, menuVisible: false)
    #expect(controller.outputCycleDeviceUIDs == ["test.disconnected"])
  }

  @Test func outputSelectionStorageIsBoundedAndCanBeClearedAtCapacity() throws {
    let suite = "XStats.AudioOutputShortcutTests.storage.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
      try JSONEncoder().encode((0..<300).map { "device.\($0)" }),
      forKey: "audio.outputCycleDevices")
    let controller = AudioController(defaults: defaults)
    defer { controller.stop() }
    #expect(controller.outputCycleDeviceUIDs?.count == 256)
    controller.setOutputCycleDevice(devices[0], included: true)
    #expect(controller.outputCycleDeviceUIDs?.count == 256)
    controller.setOutputCycleDevice(
      AudioDeviceInfo(id: 99, uid: "device.0", name: "Saved", hasOutput: true), included: false)
    controller.setOutputCycleDevice(devices[0], included: true)
    #expect(controller.outputCycleDeviceUIDs?.contains("test.a") == true)
    for uid in ["", String(repeating: "a", count: 513)] {
      controller.setOutputCycleDevice(
        AudioDeviceInfo(id: 99, uid: uid, name: "Invalid", hasOutput: true), included: true)
      #expect(controller.outputCycleDeviceUIDs?.contains(uid) == false)
    }
    for data in [Data("invalid".utf8), Data(repeating: 32, count: 1_048_577)] {
      defaults.set(data, forKey: "audio.outputCycleDevices")
      let restored = AudioController(defaults: defaults)
      #expect(restored.outputCycleDeviceUIDs == nil)
      restored.stop()
    }
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
    defaults.set(false, forKey: "audio.lowerVolumeOnHeadphoneDisconnect")
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
