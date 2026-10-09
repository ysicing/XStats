// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor struct WellnessSettingsTests {
    @Test func oldSettingsDoNotEnableRemindersAndNewPreferencesSurviveBackup() throws {
        let name = "WellnessSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // 已开启的番茄功能不能自动增加任何新提醒。
        defaults.set(true, forKey: "restEnabled")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.restEnabled)
        #expect(!settings.wellnessPreferences.breakEnabled && !settings.wellnessPreferences.waterEnabled)
        settings.wellnessPreferences.waterEnabled = true
        settings.wellnessPreferences.waterIntervalMinutes = 90
        settings.wellnessPreferences.breathingPattern = .box
        let data = try JSONEncoder().encode(settings.exportDocument())
        let document = try JSONDecoder().decode(SettingsDocument.self, from: data)
        #expect(document.wellnessPreferences == settings.wellnessPreferences)
        #expect(String(decoding: data, as: UTF8.self).contains("activities") == false)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.wellnessPreferences == settings.wellnessPreferences)
        settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
        #expect(settings.wellnessPreferences.waterEnabled)
        var invalid = SettingsDocument()
        var preferences = WellnessPreferences()
        preferences.breakSeconds = -1
        preferences.waterGoal = 999
        invalid.wellnessPreferences = preferences
        settings.apply(invalid)
        #expect(settings.wellnessPreferences.breakSeconds == 60)
        #expect(settings.wellnessPreferences.waterGoal == nil)
    }
}
