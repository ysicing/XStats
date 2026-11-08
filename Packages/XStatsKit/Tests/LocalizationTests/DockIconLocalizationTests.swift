// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
@testable import Localization

struct DockIconLocalizationTests {
  @Test func dockIconChoicesHaveTranslationsInEveryCatalog() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in ["程序坞图标", "启动台与搜索图标", "自动（跟随菜单栏）", "标准", "手绘"] {
        #expect(table.translate(source)?.isEmpty == false, "\(language): \(source)")
      }
    }
  }
}
