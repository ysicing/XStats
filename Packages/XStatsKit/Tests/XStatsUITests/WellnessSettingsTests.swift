// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor struct WellnessSettingsTests {
    @Test func legacyPreferencesKeepEyeRestAndDropRemovedFeaturesFromBackups() throws {
        let name = "WellnessSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data(#"{"breakEnabled":true,"breakIntervalMinutes":45,"breakSeconds":120,"waterEnabled":true,"waterIntervalMinutes":60,"breathingMinutes":3,"breathingPattern":"gentle","waterGoal":8}"#.utf8), forKey: "wellnessPreferences")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.wellnessPreferences.breakEnabled)
        #expect(settings.wellnessPreferences.breakIntervalMinutes == 45 && settings.wellnessPreferences.breakSeconds == 120)
        let data = try JSONEncoder().encode(settings.exportDocument())
        let document = try JSONDecoder().decode(SettingsDocument.self, from: data)
        #expect(document.wellnessPreferences == settings.wellnessPreferences)
        #expect(!String(decoding: data, as: UTF8.self).contains("waterEnabled"))
        settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
        #expect(settings.wellnessPreferences.breakEnabled)
        var invalid = SettingsDocument(); var preferences = WellnessPreferences(); preferences.breakSeconds = -1
        invalid.wellnessPreferences = preferences; settings.apply(invalid)
        #expect(settings.wellnessPreferences.breakSeconds == 60)
    }
}
