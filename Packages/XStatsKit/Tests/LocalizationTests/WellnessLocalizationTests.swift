// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct WellnessLocalizationTests {
  @Test func wellnessCatalogsCoverEveryNewSourceAndPreserveParameters() throws {
    let keys = Translations.wellnessEnglish.split(separator: "\n").compactMap {
      $0.split(separator: "\t").first.map(String.init)
    }
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys {
        let translated = try #require(table.translate(key))
        #expect(!translated.isEmpty)
      }
      #expect(L10n.translate("已记录 3 轮", language: language).contains("3"))
    }
  }
  @Test func hudStyleMenuLabelsAreAvailableInEveryLanguage() throws {
    let keys = ["迷你 HUD 样式", "数字倒计时", "进度圆环", "进度条"]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      var titles: Set<String> = []
      for key in keys {
        let title = try #require(table.translate(key))
        #expect(title.isEmpty == false)
        titles.insert(title)
      }
      #expect(titles.count == keys.count)
    }
  }

}
