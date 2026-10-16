// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct IslandSettingsLocalizationTests {
    @Test func settingsHaveTranslationsInEveryCatalog() throws {
        let sources = ["{}（内置屏幕）", "{}（外接屏幕）", "当前没有可显示的内容，请启用相关模块或选择其他内容。", "自动优先使用内置屏幕；手动选择的屏幕断开时临时回退，重新连接后恢复。", "已接通电源", "已断开电源", "电池电量低", "电池已充满", "刻线表示周期时间进度", "在屏幕顶部查看系统指标、AI 额度、电池与休息计时", "主显示账号", "自动选择账号", "选择主显示账号", "所选账号不可用", "暂无当前额度", "上次读取", "重置时间未知", "重置于：{}", "无限额度", "暂无电池数据", "未检测到内置电池，或暂时无法读取。", "预计充满：{}", "预计剩余：{}", "自动关注", "仅在收起时优先显示低电量或额度耗尽；展开后保持当前页面。",
                       "测试", "显示内容", "场景", "系统指标", "收起时显示首个已选指标。",
                       "未启用的模块自动隐藏，重新启用后恢复选择。电池基础信息独立于能耗开关。", "灵动岛设置", "悬停预览", "悬停展开", "显示屏幕", "未连接的显示器", "默认场景", "展开尺寸",
                       "与菜单栏的间距", "全屏时隐藏", "交互", "打开方式", "悬停等待时间", "移开后收起",
                       "显示样式", "悬浮胶囊", "顶部贴合", "悬浮在可用顶边下方；菜单栏隐藏时自动上移，保留设定间距。",
                       "贴合屏幕顶边，内容避开刘海和菜单栏；系统菜单优先显示。", "收起时宽度随内容调整。点击展开后会保持打开。"]
        for language in AppLanguage.allCases where language != .system && language != .chinese {
            let catalog = try #require(Translations.catalog(for: language))
            for source in sources { #expect(catalog.translate(source)?.isEmpty == false, "\(language): \(source)") }
        }
    }
}
