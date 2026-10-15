// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
@testable import Localization

struct CaptureIntegrationLocalizationTests {
    @Test func standaloneSwitchHasTranslationsInEveryCatalog() throws {
        let sources = ["截图、图片标注与录屏。", "打开独立版", "改用独立版", "改用内置版", "已安装独立版，可单独运行。切换后将停用内置功能。",
                       "正在使用独立版。", "未找到独立版，可改用内置版。",
                       "请先完成并关闭内置截图或录屏窗口，再切换。"]
        for language in AppLanguage.allCases where language != .system && language != .chinese {
            let catalog = try #require(Translations.catalog(for: language))
            for source in sources { #expect(catalog.translate(source)?.isEmpty == false, "\(language): \(source)") }
        }
    }
}
