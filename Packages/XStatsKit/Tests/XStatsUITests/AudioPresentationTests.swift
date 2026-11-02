// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import AudioControl
import Foundation
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct AudioPresentationTests {
  @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
  func outputSwitcherFitsDeviceNamesAndKeepsSelectionWithoutStartingAudio(
    direction: LayoutDirection
  ) throws {
    let (model, _, defaults, suite) = try preview()
    defer { defaults.removePersistentDomain(forName: suite) }
    let devices = [
      AudioDeviceInfo(id: 1, uid: "demo.speaker", name: "MacBook Pro Speakers", hasOutput: true),
      AudioDeviceInfo(id: 2, uid: "demo.airpods", name: "AirPods Pro", hasOutput: true),
      AudioDeviceInfo(
        id: 3, uid: "demo.display",
        name: "Studio Display Speakers · Externer Bildschirm · مكبرات الصوت", hasOutput: true),
      AudioDeviceInfo(
        id: 4, uid: "demo.lg", name: "LG UltraFine Display Audio", hasOutput: true),
    ]
    model.audio.showPreview(
      AudioHardwareSnapshot(devices: devices, outputID: 1, inputID: nil, applications: []),
      volumes: [:], outputs: [:])
    let appVolumeEnabled = model.audio.appVolumeEnabled
    model.audio.setOutputCycleDevice(devices[2], included: false)
    model.settings.hotKeys[.nextAudioOutput] = HotKey(
      keyCode: 1, modifiers: [.control, .option, .command], key: "s")
    let host = NSHostingView(
      rootView: AudioOutputSwitcher().environment(model)
        .environment(\.layoutDirection, direction).frame(width: 560))
    let size = host.fittingSize
    #expect(size.width == 560 && size.height > 150 && size.height < 360)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let path = ProcessInfo.processInfo.environment["XSTATS_AUDIO_SWITCHER_PREVIEW_DIR"] {
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      let name = direction == .rightToLeft ? "rtl.png" : "ltr.png"
      try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
    }
    #expect(model.audio.outputCycleDeviceUIDs == ["demo.speaker", "demo.airpods", "demo.lg"])
    #expect(!model.audio.isWorking && model.audio.appVolumeEnabled == appVolumeEnabled)
  }

  private func preview() throws -> (AppModel, AudioApplication, UserDefaults, String) {
    let suite = "XStats.AudioPresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let app = AudioApplication(
      id: "demo.app", name: "Music", processObjectIDs: [1], isPlaying: true)
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      magpieClient: UnavailableMagpieClient())
    model.audio.showPreview(
      AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: [app]),
      volumes: [:], outputs: [:])
    return (model, app, defaults, suite)
  }
  @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
  func appRowKeepsItsMeasuredHeightWhenTheResetActionBecomesAvailable(
    direction: LayoutDirection
  ) throws {
    let (model, app, defaults, suite) = try preview()
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = NSHostingView(
      rootView: AudioApplicationRow(app: app).environment(model).environment(\.isPopover, true)
        .environment(\.layoutDirection, direction))
    host.frame = NSRect(x: 0, y: 0, width: 296, height: 200)
    host.layoutSubtreeIfNeeded()
    let normalHeight = host.fittingSize.height
    #expect(normalHeight <= 80, "菜单栏应用行保留两行控件，避免重复刻度与反馈空白占据高度")
    model.audio.toggleAppPin(app)
    host.layoutSubtreeIfNeeded()
    #expect(abs(host.fittingSize.height - normalHeight) < 1)
    model.audio.showPreview(
      model.audio.snapshot, volumes: [app.id: try #require(AudioAppVolume(level: 1.6))],
      outputs: [:])
    host.layoutSubtreeIfNeeded()
    #expect(abs(host.fittingSize.height - normalHeight) < 1)
    let paused = AudioApplication(
      id: app.id, name: app.name, processObjectIDs: app.processObjectIDs, isPlaying: false)
    model.audio.showPreview(
      AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: [paused]),
      volumes: [app.id: try #require(AudioAppVolume(level: 1.6))], outputs: [app.id: "missing"])
    // 重建只用于替换不可变 app 参数；真实列表由相同稳定 ID 更新这一行。
    host.rootView = AudioApplicationRow(app: paused).environment(model).environment(
      \.isPopover, true
    ).environment(\.layoutDirection, direction)
    host.layoutSubtreeIfNeeded()
    #expect(abs(host.fittingSize.height - normalHeight) < 1)
  }
  @Test func microphoneStateUsesMicrophoneSymbolsAndMenuMuteIsDistinctFromMissingData() {
    #expect(AudioControlPresentation.muteSymbol(.input, muted: false) == "mic")
    #expect(AudioControlPresentation.muteSymbol(.input, muted: true) == "mic.slash")
    #expect(AudioControlPresentation.muteSymbol(.output, muted: true) == "speaker.slash")
    var muted = MenuBarReading()
    var unknown = MenuBarReading()
    muted.audioMuted = true
    unknown.audioVolume = nil
    #expect(!muted.hasSameImage(as: unknown, item: .audio, style: .icon))
    let mutedImage = MenuBarRenderer.image(
      reading: muted, items: [.audio], style: { _ in .icon }, networkStyle: .dots,
      colorizeHighLoad: false, fahrenheit: false)
    let unknownImage = MenuBarRenderer.image(
      reading: unknown, items: [.audio], style: { _ in .icon }, networkStyle: .dots,
      colorizeHighLoad: false, fahrenheit: false)
    #expect(mutedImage.tiffRepresentation != unknownImage.tiffRepresentation)
  }
}
