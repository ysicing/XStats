// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import AudioControl
import Foundation
@testable import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct AudioOutputPresentationTests {
  private func output(_ kind: AudioOutputKind, address: String? = nil) -> AudioDeviceInfo {
    AudioDeviceInfo(
      id: 1, uid: "test.output", name: "Headphones", hasOutput: true, outputVolume: 0.5,
      bluetoothAddress: address, outputKind: kind)
  }

  @Test func switchingOutputAtTheSameVolumeRefreshesOnlyStylesWithAnIcon() throws {
    let suite = "XStats.AudioOutputPresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil, aiUsageProviders: [],
      aiQuotaProviders: [])
    var previous: MenuBarReading?
    var previousImage: Data?
    for kind: AudioOutputKind in [.speaker, .headphones, .usb, .display, .bluetooth] {
      let device = output(kind)
      model.audio.showPreview(
        AudioHardwareSnapshot(
          devices: [device], outputID: device.id, inputID: nil, applications: []),
        volumes: [:], outputs: [:])
      let reading = MenuBarReading(model: model, items: [.audio])
      #expect(NSImage(systemSymbolName: reading.audioSymbol, accessibilityDescription: nil) != nil)
      let image = MenuBarRenderer.image(
        reading: reading, items: [.audio], style: { _ in .icon }, networkStyle: .dots,
        colorizeHighLoad: false, fahrenheit: false
      ).tiffRepresentation
      if let previous {
        #expect(!reading.hasSameImage(as: previous, item: .audio, style: .icon))
        #expect(reading.hasSameImage(as: previous, item: .audio, style: .inline))
        #expect(image != previousImage)
      }
      #expect(AudioControlPresentation.outputSymbol(device, muted: true) == "speaker.slash")
      previous = reading
      previousImage = image
    }
    #expect(AudioControlPresentation.outputSymbol(nil) == "speaker.wave.2")
  }

  @Test func batteryAssociationRequiresAConnectedAddressMatchWithKnownBattery() {
    let device = output(.headphones, address: "AA-BB-CC-DD-EE-FF")
    let battery = BluetoothDevice(
      name: "Renamed headset", address: "aa:bb:cc:dd:ee:ff", kind: .headphones,
      batteries: [("L", 60), ("R", 70), ("Case", 80)])
    var sameName = battery
    sameName.name = device.name
    sameName.address = "11:22:33:44:55:66"
    #expect(
      AudioControlPresentation.connectedBattery(for: device, devices: [sameName, battery])
        == battery)
    #expect(AudioControlPresentation.connectedBattery(for: device, devices: [sameName]) == nil)
    var disconnected = battery
    disconnected.isConnected = false
    disconnected.lastSeen = Date()
    var noAddress = battery
    noAddress.address = ""
    var unknown = battery
    unknown.batteries = []
    #expect(
      AudioControlPresentation.connectedBattery(
        for: device, devices: [disconnected, noAddress, unknown]) == nil)
    #expect(AudioControlPresentation.connectedBattery(for: device, devices: nil) == nil)
    #expect(
      AudioControlPresentation.connectedBattery(for: output(.speaker), devices: [battery]) == nil)
    #expect(AudioControlPresentation.connectedBattery(for: nil, devices: [battery]) == nil)
  }

  @Test func bluetoothBatteryDemandFollowsVisibleEnabledAudioControls() throws {
    let suite = "XStats.AudioBatteryDemandTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.audioEnabled = true
    settings.bluetoothLowBatteryInMenuBar = false
    settings.menuBarItems = [.audio]
    settings.panelTab = .audio
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    let bluetooth = output(.headphones, address: "AA-BB-CC-DD-EE-FF")
    model.audio.showPreview(
      AudioHardwareSnapshot(
        devices: [bluetooth], outputID: bluetooth.id, inputID: nil, applications: []),
      volumes: [:], outputs: [:])
    #expect(model.bluetoothDemand == .off, "只有菜单栏入口时不额外读取蓝牙电量")
    model.openPopover = .audio
    #expect(model.bluetoothDemand == .foreground)
    model.openPopover = nil
    #expect(model.bluetoothDemand == .off)
    model.isMainWindowVisible = true
    #expect(model.bluetoothDemand == .foreground)
    settings.panelTab = .overview
    #expect(model.bluetoothDemand == .off)
    settings.panelTab = .audio
    settings.audioEnabled = false
    #expect(model.bluetoothDemand == .off)
    settings.audioEnabled = true
    let speaker = output(.speaker)
    model.audio.showPreview(
      AudioHardwareSnapshot(
        devices: [speaker], outputID: speaker.id, inputID: nil, applications: []),
      volumes: [:], outputs: [:])
    #expect(model.bluetoothDemand == .off)
    model.openPopover = .battery
    #expect(model.bluetoothDemand == .foreground, "既有电池页面需求仍然有效")
  }
}
