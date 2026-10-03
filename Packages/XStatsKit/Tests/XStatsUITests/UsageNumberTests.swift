// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@Suite struct UsageNumberTests {
    @Test func chineseUsesReadableTokenUnits() {
        let locale = Locale(identifier: "zh_Hans_CN")
        #expect(UsageNumber.short(1_374_863_940, locale: locale) == "13.75亿")
        #expect(UsageNumber.short(1_234_567, locale: locale) == "123.5万")
        #expect(UsageNumber.short(12_345, locale: locale) == "1.2万")
        #expect(UsageNumber.short(0, locale: locale) == "0")
        #expect(UsageNumber.short(999, locale: locale) == "999")
    }
    @Test func englishAndTraditionalChineseKeepTheirUnits() {
        #expect(UsageNumber.short(1_374_863_940, locale: Locale(identifier: "en_US")) == "1.37B")
        #expect(UsageNumber.short(1_374_863_940, locale: Locale(identifier: "zh_Hant_TW")) == "13.75億")
    }
}

@Suite struct QuotaDateTests {
    @Test func sameYearOmitsYearButKeepsTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-03T00:00:00Z"))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-20T09:09:00Z"))
        let chinese = Locale(identifier: "zh_CN")
        #expect(UsageNumber.quotaDate(date, includesTime: false, now: now, locale: chinese, calendar: calendar) == "10月20日")
        let timed = UsageNumber.quotaDate(date, includesTime: true, now: now, locale: chinese, calendar: calendar)
        #expect(timed.contains("10月20日") && timed.contains("17:09") && !timed.contains("2026"))
        let english = UsageNumber.quotaDate(date, includesTime: false, now: now, locale: Locale(identifier: "en_US"), calendar: calendar)
        #expect(english == "Oct 20")
    }

    @Test(arguments: ["2025-10-20T09:09:00Z", "2027-01-01T09:09:00Z"])
    func otherYearsRemainExplicit(_ timestamp: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-03T00:00:00Z"))
        let date = try #require(ISO8601DateFormatter().date(from: timestamp))
        for locale in [Locale(identifier: "zh_CN"), Locale(identifier: "en_US")] {
            for includesTime in [true, false] {
                let text = UsageNumber.quotaDate(date, includesTime: includesTime, now: now, locale: locale, calendar: calendar)
                #expect(text.contains(String(timestamp.prefix(4))))
            }
        }
    }

    @Test func localYearBoundaryUsesTheDisplayTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-12-31T16:01:00Z"))
        let date = try #require(ISO8601DateFormatter().date(from: "2027-01-02T00:00:00Z"))
        let locale = Locale(identifier: "zh_CN")
        #expect(UsageNumber.quotaDate(date, includesTime: false, now: now, locale: locale, calendar: calendar) == "1月2日")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(UsageNumber.quotaDate(date, includesTime: false, now: now, locale: locale, calendar: calendar).contains("2027"))
    }
}
