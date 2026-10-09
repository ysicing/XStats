// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor struct RestSoundPreviewTests {
    private func fixture(_ body: (AppSettings, RestController, RestSoundPlayer) async throws -> Void) async throws {
        let name = "RestSoundPreviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        settings.restSound = .pink
        // 测试只验证引擎所有权，不向本机输出音频。
        let player = RestSoundPlayer(startEngine: { _ in })
        let rest = RestController(settings: settings, localDefaults: defaults, sharedDefaults: nil, audio: player)
        defer { rest.stop() }
        try await body(settings, rest, player)
    }

    @Test func previewEndsAfterFiveSecondsWithoutStartingFocus() async throws {
        try await fixture { _, rest, player in
            #expect(rest.startSoundPreview())
            #expect(rest.isPreviewingSound && player.playing == .pink)
            #expect(!rest.isRunning && rest.phase == .work)
            rest.syncSound()
            #expect(rest.isPreviewingSound)
            try await Task.sleep(for: .milliseconds(5200))
            #expect(!rest.isPreviewingSound && player.playing == .off)
            #expect(!rest.isRunning)
        }
    }

    @Test func stopSelectionChangesAndSuspendReleasePreview() async throws {
        try await fixture { settings, rest, player in
            #expect(rest.startSoundPreview())
            rest.stopSoundPreview()
            #expect(!rest.isPreviewingSound && player.playing == .off)
            #expect(rest.startSoundPreview())
            settings.restSound = .rain
            rest.syncSound()
            #expect(!rest.isPreviewingSound && player.playing == .off)
            #expect(rest.startSoundPreview())
            #expect(player.playing == .rain)
            rest.suspend()
            #expect(!rest.isPreviewingSound && player.playing == .off)
            settings.restSound = .off
            #expect(!rest.canPreviewSound && !rest.startSoundPreview())
            settings.restSound = .pink
            settings.restEnabled = false
            #expect(!rest.startSoundPreview())
        }
    }

    @Test func restTakesOverPreviewAndCancelledDeadlineDoesNotStopRestAudio() async throws {
        try await fixture { _, rest, player in
            #expect(rest.startSoundPreview())
            rest.setRunning(true)
            rest.skip()
            #expect(rest.isRunning && rest.phase.isResting)
            #expect(!rest.isPreviewingSound && !rest.canPreviewSound)
            #expect(player.playing == .pink)
            rest.stopSoundPreview()
            try await Task.sleep(for: .milliseconds(5200))
            #expect(player.playing == .pink)
        }
    }

    @Test func audioStartupFailureDoesNotLeavePreviewActive() throws {
        enum StartupFailure: Error { case unavailable }
        let name = "RestSoundPreviewFailure.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        settings.restSound = .pink
        let player = RestSoundPlayer(startEngine: { _ in throw StartupFailure.unavailable })
        let rest = RestController(settings: settings, localDefaults: defaults, sharedDefaults: nil, audio: player)
        defer { rest.stop() }
        #expect(!rest.startSoundPreview())
        #expect(!rest.isPreviewingSound && player.playing == .off)
    }
}
