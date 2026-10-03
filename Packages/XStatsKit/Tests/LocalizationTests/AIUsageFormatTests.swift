// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
import Localization

struct AIUsageFormatTests {
    @Test(arguments: [
        (0, "0"), (999, "999"), (1_000, "1K"), (1_234, "1.2K"),
        (100_000, "100K"), (123_456, "123K"), (999_499, "999K"),
        (999_500, "1M"), (1_000_000, "1M"), (1_234_567, "1.2M"),
        (10_000_000, "10M"), (12_345_678, "12M"), (999_499_999, "999M"),
        (999_500_000, "1B"), (1_000_000_000, "1B"), (1_234_567_890, "1.23B"),
        (-1_234, "-1.2K")
    ])
    func westernTokens(_ value: Int, _ expected: String) {
        #expect(AIUsageFormat.tokens(value, locale: Locale(identifier: "en_US")) == expected)
    }

    @Test(arguments: [
        (9_999, "9999"), (10_000, "1万"), (12_345, "1.2万"),
        (99_999_499, "9999.9万"), (99_999_500, "1亿"),
        (100_000_000, "1亿"), (123_456_789, "1.23亿")
    ])
    func simplifiedChineseTokens(_ value: Int, _ expected: String) {
        #expect(AIUsageFormat.tokens(value, locale: Locale(identifier: "zh_CN")) == expected)
    }

    @Test func tokenLocalesAndWesternOverride() {
        #expect(AIUsageFormat.tokens(12_345, locale: Locale(identifier: "zh_Hant_TW")) == "1.2萬")
        #expect(AIUsageFormat.tokens(123_456_789, locale: Locale(identifier: "zh_TW")) == "1.23億")
        #expect(AIUsageFormat.tokens(12_345, westernUnits: true, locale: Locale(identifier: "zh_CN")) == "12.3K")
        #expect(AIUsageFormat.tokens(1_234, locale: Locale(identifier: "de_DE")) == "1,2K")
        #expect(AIUsageFormat.tokens(1_234, locale: Locale(identifier: "ar_SA")) == "١٫٢K")
        #expect(!AIUsageFormat.tokens(Int.min, locale: Locale(identifier: "en_US")).isEmpty)
        #expect(!AIUsageFormat.tokens(Int.max, locale: Locale(identifier: "zh_CN")).isEmpty)
    }

    @Test func quotaClampsAndInverts() {
        #expect(AIUsageFormat.quotaValue(remainingPercent: -10, showsRemaining: true) == 0)
        #expect(AIUsageFormat.quotaValue(remainingPercent: 110, showsRemaining: true) == 100)
        #expect(AIUsageFormat.quotaValue(remainingPercent: -10, showsRemaining: false) == 100)
        #expect(AIUsageFormat.quotaValue(remainingPercent: 110, showsRemaining: false) == 0)
        #expect(AIUsageFormat.quotaValue(remainingPercent: 75, showsRemaining: false) == 25)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func unknownQuotaIsNotZero(_ value: Double) {
        #expect(AIUsageFormat.quotaValue(remainingPercent: value, showsRemaining: true) == nil)
        #expect(AIUsageFormat.quotaValue(remainingPercent: value, showsRemaining: false) == nil)
        #expect(AIUsageFormat.quotaPercent(remainingPercent: value, showsRemaining: true,
                                         locale: Locale(identifier: "en_US")) == "—")
    }

    @Test func compactQuotaPreservesEndpoints() {
        let locale = Locale(identifier: "en_US")
        #expect(AIUsageFormat.quotaPercent(remainingPercent: 0, showsRemaining: true, locale: locale, compact: true) == "0%")
        #expect(AIUsageFormat.quotaPercent(remainingPercent: 100, showsRemaining: true, locale: locale, compact: true) == "100%")
        #expect(AIUsageFormat.quotaPercent(remainingPercent: 0.4, showsRemaining: true, locale: locale, compact: true) == "<1%")
        #expect(AIUsageFormat.quotaPercent(remainingPercent: 99.6, showsRemaining: true, locale: locale, compact: true) == ">99%")
        #expect(AIUsageFormat.quotaPercent(remainingPercent: 99.6, showsRemaining: false, locale: locale, compact: true) == "<1%")
        #expect(AIUsageFormat.quotaPercent(remainingPercent: 0, showsRemaining: false, locale: locale, compact: true) == "100%")
        #expect(AIUsageFormat.quotaPercent(remainingPercent: 99.6, showsRemaining: true, locale: locale) == "99.6%")
        #expect(AIUsageFormat.quotaPercent(remainingPercent: 99.6, showsRemaining: false, locale: locale) == "0.4%")
    }

    @Test func percentUsesExplicitLocale() {
        let arabic = AIUsageFormat.quotaPercent(remainingPercent: 12.3, showsRemaining: true, locale: Locale(identifier: "ar_SA"))
        #expect(arabic.contains("١٢٫٣"))
        #expect(arabic.contains("٪"))
        let german = AIUsageFormat.quotaPercent(remainingPercent: 12.3, showsRemaining: true, locale: Locale(identifier: "de_DE"))
        #expect(german.contains("12,3"))
    }

    @Test(arguments: [(0.0, "$0"), (0.0123, "$0.012"), (1.234, "$1.23"), (100.49, "$100")])
    func dollarsUseMagnitudePrecision(_ value: Double, _ expected: String) {
        #expect(AIUsageFormat.money(usd: value, currency: .usd, usdToCNY: nil,
                                  locale: Locale(identifier: "en_US")) == expected)
    }

    @Test func yuanRequiresExchangeRateAndConvertsForDisplay() {
        let usd = 2.0
        let locale = Locale(identifier: "zh_CN")
        #expect(AIUsageFormat.money(usd: usd, currency: .cny, usdToCNY: nil, locale: locale) == nil)
        #expect(AIUsageFormat.money(usd: usd, currency: .cny, usdToCNY: 7.25, locale: locale) == "¥14.5")
        #expect(usd == 2)
        #expect(AIUsageCurrency.usd.currencyCode == "USD")
        #expect(AIUsageCurrency.cny.currencyCode == "CNY")
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -1])
    func rejectsInvalidMoney(_ value: Double) {
        #expect(AIUsageFormat.money(usd: value, currency: .usd, usdToCNY: nil,
                                  locale: Locale(identifier: "en_US")) == nil)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -1, 0])
    func rejectsInvalidRates(_ rate: Double) {
        #expect(AIUsageFormat.money(usd: 1, currency: .cny, usdToCNY: rate,
                                  locale: Locale(identifier: "zh_CN")) == nil)
    }

    @Test func rejectsConversionOverflow() {
        #expect(AIUsageFormat.money(usd: Double.greatestFiniteMagnitude, currency: .cny,
                                  usdToCNY: 2, locale: Locale(identifier: "zh_CN")) == nil)
    }
}
