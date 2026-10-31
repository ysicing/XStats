// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct CommandBarLocalizationTests {
  @Test(arguments: AppLanguage.allCases.filter { $0 != .system && $0 != .chinese })
  func newCommandLabelsHaveExplicitTranslations(language: AppLanguage) throws {
    let table = try #require(Translations.catalog(for: language))
    for key in ["命令栏", "搜索功能与操作", "暂停专注", "开启防休眠", "停止防休眠"] {
      #expect(table.sourceKeys.contains(key), "\(language): \(key)")
      #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
    }
  }
}
