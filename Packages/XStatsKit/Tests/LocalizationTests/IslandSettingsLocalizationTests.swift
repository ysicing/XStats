// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct IslandSettingsLocalizationTests {
    @Test func settingsHaveTranslationsInEveryCatalog() throws {
        let sources = ["显示内容", "场景", "系统指标", "收起时显示首个已选指标。",
                       "仅选择灵动岛显示的内容；未启用的功能需先在主应用中开启。", "灵动岛设置", "悬停预览", "悬停展开", "显示屏幕", "未连接的显示器", "默认场景", "展开尺寸",
                       "与菜单栏的间距", "全屏时隐藏", "交互", "打开方式", "悬停等待时间", "移开后收起",
                       "显示样式", "悬浮胶囊", "顶部贴合", "悬浮在菜单栏下方，可调整间距。",
                       "贴合屏幕顶边，内容避开刘海和菜单栏；系统菜单优先显示。", "收起时宽度随内容调整。点击展开后会保持打开。"]
        for language in AppLanguage.allCases where language != .system && language != .chinese {
            let catalog = try #require(Translations.catalog(for: language))
            for source in sources { #expect(catalog.translate(source)?.isEmpty == false, "\(language): \(source)") }
        }
    }
}
