// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// AI 费用的显示币种；底层统计始终保存美元金额。
public enum AIUsageCurrency: String, CaseIterable, Codable, Sendable {
    case usd
    case cny

    public var currencyCode: String {
        switch self {
        case .usd: "USD"
        case .cny: "CNY"
        }
    }
}

/// 主应用与 Widget 共用的纯显示格式化，不读取或修改全局语言偏好。
public enum AIUsageFormat {
    /// 按指定语言缩写 token 数；中文默认使用万、亿，西式单位为 K、M、B。
    public static func tokens(_ value: Int, westernUnits: Bool = false, locale: Locale) -> String {
        let number = Double(value)
        let magnitude = abs(number)
        let divisor: Double
        let suffix: String
        let fractionDigits: Int

        if !westernUnits, locale.language.languageCode?.identifier == "zh" {
            let traditional = locale.language.script?.identifier == "Hant"
            // 在低档位舍入会抵达下一单位时提前升档，避免显示 10000 万。
            if magnitude >= 99_999_500 {
                divisor = 100_000_000
                suffix = traditional ? "億" : "亿"
                fractionDigits = 2
            } else if magnitude >= 10_000 {
                divisor = 10_000
                suffix = traditional ? "萬" : "万"
                fractionDigits = 1
            } else {
                return value.formatted(.number.locale(locale).grouping(.never))
            }
        } else {
            // K/M 的大数档取整；跨界前提前升档，避免 1000K 和 1000M。
            if magnitude >= 999_500_000 {
                divisor = 1_000_000_000
                suffix = "B"
                fractionDigits = 2
            } else if magnitude >= 999_500 {
                divisor = 1_000_000
                suffix = "M"
                fractionDigits = magnitude >= 10_000_000 ? 0 : 1
            } else if magnitude >= 1_000 {
                divisor = 1_000
                suffix = "K"
                fractionDigits = magnitude >= 100_000 ? 0 : 1
            } else {
                return value.formatted(.number.locale(locale).grouping(.never))
            }
        }

        return (number / divisor).formatted(
            .number.locale(locale).grouping(.never).precision(.fractionLength(0...fractionDigits))
        ) + suffix
    }

    /// 将有效剩余额度限制到 0...100，再按显示方向返回剩余或已用百分数。
    public static func quotaValue(remainingPercent: Double, showsRemaining: Bool) -> Double? {
        guard remainingPercent.isFinite else { return nil }
        let remaining = min(100, max(0, remainingPercent))
        return showsRemaining ? remaining : 100 - remaining
    }

    /// 格式化额度百分数；未知值显示破折号，紧凑显示保留接近空额、满额的区别。
    public static func quotaPercent(
        remainingPercent: Double, showsRemaining: Bool, locale: Locale, compact: Bool = false
    ) -> String {
        guard let value = quotaValue(remainingPercent: remainingPercent, showsRemaining: showsRemaining) else {
            return "—"
        }
        let style = FloatingPointFormatStyle<Double>.Percent(locale: locale)
            .precision(.fractionLength(0...(compact ? 0 : 1)))
        if compact, value > 0, value < 1 {
            return "<" + 0.01.formatted(style)
        }
        if compact, value > 99, value < 100 {
            return ">" + 0.99.formatted(style)
        }
        return (value / 100).formatted(style)
    }

    /// 仅在显示时兑换美元金额；无效金额、缺失汇率或乘法上溢返回 nil。
    /// 此接口仅接受美元费用，不用于 credits 等非货币计量。
    public static func money(
        usd: Double, currency: AIUsageCurrency, usdToCNY: Double?, locale: Locale
    ) -> String? {
        guard usd.isFinite, usd >= 0 else { return nil }
        let amount: Double
        switch currency {
        case .usd:
            amount = usd
        case .cny:
            guard let rate = usdToCNY, rate.isFinite, rate > 0 else { return nil }
            amount = usd * rate
        }
        guard amount.isFinite else { return nil }
        let fractionDigits = amount >= 100 ? 0 : amount >= 1 ? 2 : 3
        return amount.formatted(
            .currency(code: currency.currencyCode).locale(locale)
                .precision(.fractionLength(0...fractionDigits))
        )
    }
}
