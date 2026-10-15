// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
@testable import Localization

struct CaptureIntegrationLocalizationTests {
    @Test func captureFeedbackHasTranslationsInEveryCatalog() throws {
        let sources = ["正在预览窗口…", "窗口预览未完成，请重新选择。", "目标窗口当前不可见", "马赛克", "颗粒大小", "一键打码", "在本机识别手机号、邮箱、身份证号和银行卡号。", "正在识别敏感信息…", "未发现新的敏感信息，可手动补充马赛克。", "已添加 {} 处马赛克，请检查并补充遗漏。", "标注数量已达上限，请先删除部分标注。", "敏感信息识别未完成，请重试。"]
        for language in AppLanguage.allCases where language != .system && language != .chinese {
            let catalog = try #require(Translations.catalog(for: language))
            for source in sources { #expect(catalog.translate(source)?.isEmpty == false, "\(language): \(source)") }
        }
    }
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
