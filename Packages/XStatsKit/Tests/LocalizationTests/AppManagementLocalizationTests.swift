// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct AppManagementLocalizationTests {
    @Test func appManagementTextExistsInEverySupportedCatalog() throws {
        let sources = Translations.applicationManagementEnglish.split(separator: "\n").compactMap { line -> String? in
            guard let separator = line.firstIndex(of: "\t") else { return nil }
            return String(line[..<separator])
        }
        for language in AppLanguage.allCases where language != .system && language != .chinese {
            let table = try #require(Translations.catalog(for: language))
            for source in sources { #expect(table.translate(source) != nil, "\(language): \(source)") }
        }
    }
}
