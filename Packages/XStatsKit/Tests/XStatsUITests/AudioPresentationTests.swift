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
    private func preview() throws -> (AppModel, AudioApplication, UserDefaults, String) {
        let suite = "XStats.AudioPresentationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AudioApplication(id: "demo.app", name: "Music", processObjectIDs: [1], isPlaying: true)
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        model.audio.showPreview(AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: [app]), volumes: [:], outputs: [:])
        return (model, app, defaults, suite)
    }
    @Test func appRowKeepsItsMeasuredHeightWhenTheResetActionBecomesAvailable() throws {
        let (model, app, defaults, suite) = try preview()
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: AudioApplicationRow(app: app).environment(model).environment(\.isPopover, true))
        host.frame = NSRect(x: 0, y: 0, width: 296, height: 200)
        host.layoutSubtreeIfNeeded()
        let normalHeight = host.fittingSize.height
        #expect(normalHeight <= 80, "菜单栏应用行保留两行控件，避免重复刻度与反馈空白占据高度")
        model.audio.showPreview(model.audio.snapshot, volumes: [app.id: try #require(AudioAppVolume(level: 1.6))], outputs: [:])
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - normalHeight) < 1)
        let paused = AudioApplication(id: app.id, name: app.name, processObjectIDs: app.processObjectIDs, isPlaying: false)
        model.audio.showPreview(AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: [paused]),
                                volumes: [app.id: try #require(AudioAppVolume(level: 1.6))], outputs: [app.id: "missing"])
        // 重建只用于替换不可变 app 参数；真实列表由相同稳定 ID 更新这一行。
        host.rootView = AudioApplicationRow(app: paused).environment(model).environment(\.isPopover, true)
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - normalHeight) < 1)
    }
    @Test func microphoneStateUsesMicrophoneSymbolsAndMenuMuteIsDistinctFromMissingData() {
        #expect(AudioControlPresentation.muteSymbol(.input, muted: false) == "mic")
        #expect(AudioControlPresentation.muteSymbol(.input, muted: true) == "mic.slash")
        #expect(AudioControlPresentation.muteSymbol(.output, muted: true) == "speaker.slash")
        var muted = MenuBarReading(), unknown = MenuBarReading()
        muted.audioMuted = true
        unknown.audioVolume = nil
        #expect(!muted.hasSameImage(as: unknown, item: .audio, style: .icon))
        let mutedImage = MenuBarRenderer.image(reading: muted, items: [.audio], style: { _ in .icon }, networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
        let unknownImage = MenuBarRenderer.image(reading: unknown, items: [.audio], style: { _ in .icon }, networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
        #expect(mutedImage.tiffRepresentation != unknownImage.tiffRepresentation)
    }
}
