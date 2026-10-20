// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct AudioBluetoothLocalizationTests {
  @Test func audioControlsHaveExplicitTranslationsInEveryLanguage() throws {
    let keys = Translations.audioEnglish.split(separator: "\n").compactMap {
      $0.split(separator: "\t").first.map(String.init)
    }
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys { #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)") }
    }
  }
}
