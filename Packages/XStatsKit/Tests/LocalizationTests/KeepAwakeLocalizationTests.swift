// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct KeepAwakeLocalizationTests {
  @Test(arguments: AppLanguage.allCases.filter { $0 != .system && $0 != .chinese })
  func batteryProtectionLabelsAndThresholdNoticeAreTranslated(language: AppLanguage) throws {
    let table = try #require(Translations.catalog(for: language))
    for key in [
      "低电量保护", "低电量时停止防休眠", "用于合盖运行保护和低电量停止防休眠",
      "电量低于 {}%，防休眠已关闭",
    ] {
      #expect(table.sourceKeys.contains(key), "\(language): \(key)")
    }
    let notice = try #require(table.translate("电量低于 40%，防休眠已关闭"))
    #expect(notice.contains("40"))
    #expect(!notice.contains("{}") && !notice.contains("防休眠已关闭"))
  }
}
