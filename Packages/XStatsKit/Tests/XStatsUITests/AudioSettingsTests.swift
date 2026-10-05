// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct AudioSettingsTests {
    @Test func disabledModuleRetainsMenuPreferencesAndRedirectsItsPage() throws {
        let name = "XStats.AudioSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.audioEnabled)
        settings.menuBarItems = [.audio]
        #expect(settings.orderedMenuBarItems.isEmpty)
        settings.audioEnabled = true
        settings.panelTab = .audio
        #expect(settings.orderedMenuBarItems == [.audio])
        settings.audioEnabled = false
        #expect(settings.menuBarItems == [.audio])
        #expect(settings.orderedMenuBarItems.isEmpty)
        #expect(settings.panelTab == .settingsFeatures)
        #expect(AppSettings(defaults: defaults).panelTab == .settingsFeatures)
    }

    @Test func audioPopoverAndSummaryDoNotRaiseMetricSamplingFrequency() throws {
        let name = "XStats.AudioDemandTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.audioEnabled = true
        settings.menuBarItems = [.audio]
        settings.refreshSeconds = 5
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        model.openPopover = .audio
        #expect(model.demand.interval == .seconds(5))
        model.isCombinedPopoverOpen = true
        model.combinedPopoverTab = nil
        #expect(model.demand.interval == .seconds(5))
        #expect(model.audioMenuVisible)
        #expect(!model.audioControlsVisible)
        model.combinedPopoverTab = .audio
        #expect(model.audioControlsVisible)
        #expect(model.demand.interval == .seconds(5))
        // OS grants and app gains never enter the backup document.
        #expect(settings.exportDocument().audioEnabled == true)
        #expect(model.audio.snapshot == .empty)
    }
}
