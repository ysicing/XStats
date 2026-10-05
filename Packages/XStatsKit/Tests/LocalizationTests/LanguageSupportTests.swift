// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Localization

struct LanguageSupportTests {
    @Test func containsExactlyNineLanguagesAndAutomaticDetection() {
        #expect(AppLanguage.allCases.count == 10)
        #expect(Set(AppLanguage.allCases.filter { $0 != .system }.map(\.languageCode)) ==
                Set(["zh-Hans", "zh-Hant", "ja", "ko", "en", "de", "es", "fr", "ar"]))
        #expect(AppLanguage(rawValue: "chinese") == .chinese)
        #expect(AppLanguage(rawValue: "english") == .english)
        #expect(AppLanguage(rawValue: "system") == .system)
    }

    @Test func resolvesScriptsRegionsAndPreferenceOrder() {
        for value in ["zh-Hant", "zh-TW", "zh-HK", "zh_MO", "zh-Hant-CN"] {
            #expect(AppLanguage.resolve(preferredLanguages: [value]) == .traditionalChinese)
        }
        for value in ["zh-Hans", "zh-CN", "zh-SG", "zh-Hans-TW", "zh"] {
            #expect(AppLanguage.resolve(preferredLanguages: [value]) == .chinese)
        }
        #expect(AppLanguage.resolve(preferredLanguages: ["ru-RU", "ja-JP", "en"]) == .japanese)
        #expect(AppLanguage.resolve(preferredLanguages: ["es-MX", "zh-CN"]) == .spanish)
        #expect(AppLanguage.resolve(preferredLanguages: ["ar-EG"]) == .arabic)
        #expect(AppLanguage.resolve(preferredLanguages: ["ko-KR"]) == .korean)
        #expect(AppLanguage.resolve(preferredLanguages: ["de-CH"]) == .german)
        #expect(AppLanguage.resolve(preferredLanguages: ["fr-CA"]) == .french)
        #expect(AppLanguage.resolve(preferredLanguages: ["ru"]) == .english)
        #expect(AppLanguage.resolve(preferredLanguages: []) == .english)
    }

    @Test func searchesNativeChineseEnglishAndAccents() {
        #expect(AppLanguage.japanese.matches(search: "日语"))
        #expect(AppLanguage.japanese.matches(search: "日本"))
        #expect(AppLanguage.german.matches(search: "german"))
        #expect(AppLanguage.german.matches(search: "DEUTSCH"))
        #expect(AppLanguage.french.matches(search: "francais"))
        #expect(AppLanguage.spanish.matches(search: "espanol"))
        #expect(AppLanguage.arabic.matches(search: "العربية"))
        #expect(AppLanguage.traditionalChinese.matches(search: "繁体"))
        #expect(AppLanguage.system.matches(search: "auto"))
        #expect(AppLanguage.allCases.allSatisfy { $0.matches(search: "  ") })
        #expect(AppLanguage.allCases.contains { $0.matches(search: "zzzzzz") } == false)
    }

    @Test func setsProcessLocaleWithoutChangingOtherPreferences() {
        let name = "LanguageSupportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("keep", forKey: "unrelated")
        AppLanguage.traditionalChinese.applyToProcessLocale(defaults: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hant"])
        #expect(defaults.string(forKey: "AppleLocale")?.hasPrefix("zh_Hant_") == true)
        AppLanguage.arabic.applyToProcessLocale(defaults: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ar"])
        AppLanguage.system.applyToProcessLocale(defaults: defaults)
        // 移除应用覆盖后 UserDefaults 会继承全局值，应检查自身域而不是合并后的查询结果。
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
        #expect(defaults.persistentDomain(forName: name)?["AppleLocale"] == nil)
        #expect(defaults.string(forKey: "unrelated") == "keep")
        #expect(AppLanguage.arabic.isRightToLeft)
        #expect(AppLanguage.french.isRightToLeft == false)
        #expect(L10n.locale(for: .french).language.languageCode?.identifier == "fr")
    }

    @Test func templatesPreserveLiteralBracesAndTranslateNestedValues() {
        let table = Translations(tables: ["内存\tMemory\n打开 {}\tOpen {}\n{} / {}\t{2} then {1}"])
        #expect(table.translate("打开 config{}.json") == "Open config{}.json")
        #expect(table.translate("打开 内存") == "Open Memory")
        #expect(table.translate("first / second") == "second then first")
        let rtl = Translations(tables: ["地址：{}\tالعنوان: {}"], rightToLeft: true)
        #expect(rtl.translate("地址：192.0.2.1") == "العنوان: \u{2068}192.0.2.1\u{2069}")
    }

    @Test func rejectsBrokenPlaceholdersAndEmptyTranslations() {
        let table = Translations(tables: ["下载 {}\tDownload\n{} / {}\t{1} twice {1}\n设置\t\n内存\tMemory"])
        #expect(table.sourceKeys == ["内存"])
        #expect(table.translate("下载 file.zip") == nil)
    }

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system && $0 != .chinese })
    func everyLanguageHasCompleteCatalog(_ language: AppLanguage) throws {
        let catalog = try #require(Translations.catalog(for: language))
        #expect(catalog.sourceKeys == Translations.shared.sourceKeys)
        for key in ["应用输出设备", "系统默认输出", "重试应用音频", "已暂停", "恢复原始音量与默认输出",
                    "应用音量支持 0–200%；高增益时自动限制峰值，不改变系统音量。", "音频", "系统音量、音频设备与应用音量", "应用音量", "开启应用音量",
                    "没有可用音频设备", "输出设备", "输入设备", "输入音量", "取消静音", "恢复原始音量",
                    "语言", "应用 UI 语言", "自动检测", "搜索语言", "没有匹配的语言",
                    "热压力：正常", "热压力：偏高", "热压力：严重", "热压力：临界", "热压力：未知",
                    "高效处理多线程任务", "由 macOS 报告的系统热状态，与 CPU 温度读数独立。",
                    "核心最高温度；余量以 100°C 为参考，不代表设备实际降频阈值。",
                    "亮度", "对比度", "音量", "显示器 {} 台", "重新检测显示器控制",
                    "显示器不支持此控制", "暂时无法读取，请检查 DDC/CI 与连接",
                    "显示链路正在恢复…", "修改未确认，请重新检测",
                    "合并显示", "仅图标", "面板项目", "启动中…", "正在启动风扇…",
                    "只显示 XStats 图标，点击查看已选项目的状态总览",
                    "所选项目显示在弹出面板中，原有图标风格会保留。", "打开进程监控",
                    "额度显示", "数字单位", "货币", "估算费用",
                    "30 天", "按小时统计", "按天统计", "暂无小时明细，请刷新用量。",
                    "套餐：Pro", "套餐有效期至：2026-10-20", "可用重置次数：3", "重置次数最早到期：2026-10-05",
                    "AI 用量与额度共用此间隔；新数据到达后更新菜单栏。",
                    "价格来源：models.dev；人民币按缓存汇率换算。",
                    "按模型基础 API 单价估算，不含阶梯加价，非订阅账单。",
                    "设置", "内存", "下载并应用", "中国大陆节假日与调休", "黄历", "每日", "每周", "累计",
                    "XStats 基于 OpenStats 开发，感谢原项目的开源贡献 · MIT License"] {
            #expect(catalog.translate(key)?.isEmpty == false)
        }
    }
}
