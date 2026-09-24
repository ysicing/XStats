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

    @Test func resolvesscriptsRegionsAndPreferenceOrder() {
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
        for key in ["语言", "应用 UI 语言", "自动检测", "搜索语言", "没有匹配的语言",
                    "设置", "内存", "下载并应用", "XStats 基于 OpenStats 开发，感谢原项目的开源贡献 · MIT License"] {
            #expect(catalog.translate(key)?.isEmpty == false)
        }
    }
}
