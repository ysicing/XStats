// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Testing
@testable import XStatsUI

@MainActor
struct LanguageSettingsTests {
    @Test(arguments: AppLanguage.allCases)
    func restoresAndExportsEveryLanguage(_ language: AppLanguage) throws {
        let name = "LanguageSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(language.rawValue, forKey: AppSettings.languageKey)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.language == language)
        let document = settings.exportDocument()
        let decoded = try JSONDecoder().decode(SettingsDocument.self, from: JSONEncoder().encode(document))
        #expect(AppLanguage(rawValue: try #require(decoded.language)) == language)
    }
}
