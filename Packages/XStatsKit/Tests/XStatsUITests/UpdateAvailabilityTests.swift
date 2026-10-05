// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
import Updates
@testable import XStatsUI

@MainActor
struct UpdateAvailabilityTests {
    private func release(_ version: String) -> UpdateRelease {
        UpdateRelease(version: version, build: "200", date: "2026-10-05", minimumSystem: "14.0",
                      url: URL(string: "https://example.invalid/XStats.zip")!, sha256: String(repeating: "a", count: 64),
                      size: 1000, dmg: nil, notes: [], changelog: nil)
    }

    @Test func presentingKnownReleaseKeepsItAvailableWithoutCheckingOrInstalling() throws {
        let suite = "UpdateAvailabilityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.notifyUpdates = false
        settings.updateCheckSchedule = .never
        let controller = UpdateController(settings: settings, defaults: defaults)
        var prompts = 0
        controller.onPrompt = { prompts += 1 }
        #expect(!controller.hasAvailableUpdate)
        controller.presentAvailableUpdate()
        #expect(prompts == 0)
        controller.showPreview(release("1.0.0"))
        controller.presentAvailableUpdate()
        controller.presentAvailableUpdate()
        #expect(prompts == 2 && controller.hasAvailableUpdate)
        #expect(controller.phase == .available && controller.lastChecked == nil)
        #expect(controller.release?.version == "1.0.0")
    }

    @Test func skippedReleaseStaysHiddenAfterSparkleClearsTheCompatibilityRecord() throws {
        let suite = "UpdateAvailabilityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("1.0.0", forKey: "updateSkippedVersion")
        let controller = UpdateController(settings: AppSettings(defaults: defaults), defaults: defaults)
        var prompts = 0
        controller.onPrompt = { prompts += 1 }
        controller.showPreview(release("1.0.0"))
        #expect(!controller.hasAvailableUpdate)
        controller.presentAvailableUpdate()
        #expect(prompts == 0)
        controller.finishSkipMigration()
        #expect(controller.skippedVersion == nil && controller.release == nil)
        #expect(controller.phase == .idle && !controller.isBusy)
        #expect(!controller.hasAvailableUpdate)
        #expect(defaults.string(forKey: "updateSkippedVersion") == nil)
        controller.showPreview(release("1.0.1"))
        #expect(controller.hasAvailableUpdate)
        controller.presentAvailableUpdate()
        #expect(prompts == 1)
    }

    @Test func completingAnOlderSkipPreservesANewerCachedRelease() throws {
        let suite = "UpdateAvailabilityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("1.0.0", forKey: "updateSkippedVersion")
        let controller = UpdateController(settings: AppSettings(defaults: defaults), defaults: defaults)
        controller.showPreview(release("1.0.1"))
        controller.finishSkipMigration()
        #expect(controller.release?.version == "1.0.1" && controller.hasAvailableUpdate)
    }
}
