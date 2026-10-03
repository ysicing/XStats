// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct AIUsageSettingsTests {
    @Test func oldPreferencesKeepDefaultsAndNewChoicesPersist() throws {
        let name = "AIUsageSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.aiQuotaShowsRemaining)
        #expect(!settings.aiUsageWesternUnits)
        #expect(settings.aiUsageCurrency == .usd)
        #expect(settings.aiUsageRefreshMinutes == 30)
        settings.aiQuotaShowsRemaining = false
        settings.aiUsageWesternUnits = true
        settings.aiUsageCurrency = .cny
        for interval in [1, 3, 5, 10, 15, 30, 60] {
            settings.aiUsageRefreshMinutes = interval
            let restored = AppSettings(defaults: defaults)
            #expect(restored.aiUsageRefreshMinutes == interval)
            #expect(!restored.aiQuotaShowsRemaining)
            #expect(restored.aiUsageWesternUnits)
            #expect(restored.aiUsageCurrency == .cny)
        }
        defaults.set("invalid", forKey: "aiUsageCurrency")
        defaults.set(0, forKey: "aiUsageRefreshMinutes")
        let repaired = AppSettings(defaults: defaults)
        #expect(repaired.aiUsageCurrency == .usd)
        #expect(repaired.aiUsageRefreshMinutes == 30)
    }
}
