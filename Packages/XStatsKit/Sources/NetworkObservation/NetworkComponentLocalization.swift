// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Localization

/// 自定义 XPC/注册 CLI 错误传中文源文案键，由接收界面翻译，避免共享服务把某个客户端的语言固化进回复。
public enum NetworkComponentLocalization {
    public static let transportLanguage = AppLanguage.chinese

    /// 组件 GUI 和系统过滤配置名称沿用主程序语言；未选择时才跟随系统。
    public static var applicationLanguage: AppLanguage {
        let preferences = UserDefaults(suiteName: "work.12306.xstats.app")
        return resolve(storedLanguage: preferences?.string(forKey: "language"), preferredLanguages: Locale.preferredLanguages)
    }

    public static func resolve(storedLanguage: String?, preferredLanguages: [String]) -> AppLanguage {
        if let storedLanguage, let language = AppLanguage(rawValue: storedLanguage), language != .system { return language }
        return AppLanguage.resolve(preferredLanguages: preferredLanguages)
    }
}
