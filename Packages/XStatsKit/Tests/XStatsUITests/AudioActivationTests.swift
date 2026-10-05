// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AudioControl
@testable import XStatsUI

private final class ActivationProbe: AudioAccessProbe {
    let denied: Bool
    init(denied: Bool) { self.denied = denied }
    func start(shouldContinue: () -> Bool) throws {
        if denied { throw AudioControlError.permissionRequired }
        if !shouldContinue() { throw CancellationError() }
    }
    func stop() throws { }
}

@MainActor
struct AudioActivationTests {
    @Test func migrationPreservesTheUsersExistingActivationChoice() throws {
        let suite = "XStats.AudioActivationMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "audio.captureAuthorized")
        let controller = AudioController(defaults: defaults)
        #expect(controller.appVolumeEnabled)
        #expect(defaults.bool(forKey: "audio.appVolumeEnabled"))
        #expect(defaults.object(forKey: "audio.captureAuthorized") == nil)
    }

    @Test(arguments: [false, true])
    func activationPreferenceChangesOnlyAfterSuccessfulInitialization(denied: Bool) async throws {
        let suite = "XStats.AudioActivationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mixer = AudioMixerClient(automaticHealthChecks: false, accessProbeFactory: { ActivationProbe(denied: denied) }) { _, _, _ in
            throw AudioControlError.unavailable
        }
        let controller = AudioController(defaults: defaults, mixer: mixer)
        defer { controller.stop() }
        // 不打开设备界面，避免读取真实蓝牙目录；只验证用户开启偏好的发布时机。
        controller.setDemand(enabled: true, visible: false, menuVisible: true)
        controller.authorizeMixing()
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!controller.isWorking)
        #expect(controller.appVolumeEnabled == !denied)
        #expect(defaults.bool(forKey: "audio.appVolumeEnabled") == !denied)
        #expect(defaults.object(forKey: "audio.captureAuthorized") == nil)
        #expect(controller.error == (denied ? .permissionRequired : nil))
    }

    @Test func explicitActivationPreferenceTakesPrecedenceOverTheLegacyFlag() throws {
        let suite = "XStats.AudioActivationMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "audio.captureAuthorized")
        defaults.set(false, forKey: "audio.appVolumeEnabled")
        let controller = AudioController(defaults: defaults)
        #expect(!controller.appVolumeEnabled)
        #expect(defaults.object(forKey: "audio.captureAuthorized") == nil)
    }
}
