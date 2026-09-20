// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation

/// 保留 system / chinese / english 的持久化值，已有本机设置及 WebDAV 备份可继续读取。
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, chinese, traditionalChinese, japanese, korean, english, german, spanish, french, arabic

    public var languageCode: String {
        switch self {
        case .system: resolved.languageCode
        case .chinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        case .japanese: "ja"
        case .korean: "ko"
        case .english: "en"
        case .german: "de"
        case .spanish: "es"
        case .french: "fr"
        case .arabic: "ar"
        }
    }

    public var nativeName: String {
        switch self {
        case .system: "自动检测"
        case .chinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .english: "English"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .french: "Français"
        case .arabic: "العربية"
        }
    }

    public var isRightToLeft: Bool { (self == .system ? resolved : self) == .arabic }
    public var isChinese: Bool { self == .chinese || self == .traditionalChinese }

    /// 用户可按母语名称、中文名、英文名或语言代码搜索，忽略大小写和重音。
    public func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let aliases: String
        switch self {
        case .system: aliases = "system auto detect automatically 自动检测 跟随系统"
        case .chinese: aliases = "Simplified Chinese 中文 简体 zh-CN zh-SG"
        case .traditionalChinese: aliases = "Traditional Chinese 中文 繁体中文 繁體 zh-TW zh-HK zh-MO"
        case .japanese: aliases = "Japanese 日语 日文 日本語"
        case .korean: aliases = "Korean 韩语 韓語 韩文 한국어"
        case .english: aliases = "English 英语 英語 英文"
        case .german: aliases = "German 德语 德語"
        case .spanish: aliases = "Spanish 西班牙语 西班牙語"
        case .french: aliases = "French 法语 法語"
        case .arabic: aliases = "Arabic 阿拉伯语 阿拉伯語"
        }
        let haystack = "\(nativeName) \(languageCode) \(aliases)"
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                              locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    /// 按用户的首选顺序选择支持的语言；不支持的首选项可回退到列表中的下一项。
    public static func resolve(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
            guard let base = parts.first else { continue }
            switch base {
            case "zh":
                if parts.contains("hans") { return .chinese }
                if parts.contains("hant") || parts.contains("tw") || parts.contains("hk") || parts.contains("mo") {
                    return .traditionalChinese
                }
                return .chinese
            case "ja": return .japanese
            case "ko": return .korean
            case "en": return .english
            case "de": return .german
            case "es": return .spanish
            case "fr": return .french
            case "ar": return .arabic
            default: continue
            }
        }
        return .english
    }

    /// 读取全局首选语言，避免被应用自己写入的 AppleLanguages 覆盖。
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return Self.resolve(preferredLanguages: global ?? Locale.preferredLanguages)
    }

    /// 只修改语言，保留用户地区；系统提供的部分文字在下次启动时更新。
    public func applyToProcessLocale(defaults: UserDefaults = .standard) {
        guard self != .system else {
            defaults.removeObject(forKey: "AppleLanguages")
            defaults.removeObject(forKey: "AppleLocale")
            return
        }
        let global = CFPreferencesCopyValue("AppleLocale" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        let region = global.flatMap { Locale(identifier: $0).region?.identifier } ?? "US"
        defaults.set([languageCode], forKey: "AppleLanguages")
        defaults.set(languageCode.replacingOccurrences(of: "-", with: "_") + "_" + region, forKey: "AppleLocale")
    }
}
