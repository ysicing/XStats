// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct SyncLocalizationTests {
  @Test func syncKeysHaveExplicitTranslationsInEveryCatalog() throws {
    let keys = Translations(tables: [Translations.syncEnglish]).sourceKeys
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let catalog = try #require(Translations.catalog(for: language))
      for key in keys {
        #expect(catalog.sourceKeys.contains(key), "\(language): \(key)")
      }
    }
  }

  @Test func syncTemplatesPreserveIntervalsDatesAndConflictOptions() throws {
    let samples = [
      ("每 30 分钟", ["30"]),
      ("最近同步 11/25 14:05", ["11/25 14:05"]),
      ("Mac-A：Option-B", ["Mac-A", "Option-B"]),
      ("将应用 11/25 14:05 保存的设置，覆盖本机对应偏好。", ["11/25 14:05"]),
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let catalog = try #require(Translations.catalog(for: language))
      for (source, values) in samples {
        let rendered = try #require(catalog.translate(source))
        for value in values {
          let expected = language.isRightToLeft ? "\u{2068}\(value)\u{2069}" : value
          #expect(rendered.contains(expected), "\(language): \(source)")
        }
      }
    }
  }
}
