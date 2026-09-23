// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct CalendarAlmanacTests {
    @Test func referenceDateMatchesAlmanacFields() throws {
        let day = try #require(CalendarEngine.day(year: 2026, month: 9, day: 23))
        let detail = try #require(CalendarEngine.almanac(for: day))
        #expect(detail.sound == "壁上土")
        #expect(detail.opposingZodiac == "马")
        #expect(detail.ominousDirection == "南")
        #expect(detail.twelveStar == "司命")
        #expect(detail.twelveStarIsLucky)
        #expect(detail.duty == "平")
        #expect(detail.fetus == "占碓磨 房内南")
        #expect(detail.pengZu == ["庚不经络织机虚张", "子不问卜自惹祸殃"])
        #expect(detail.star == "箕水豹")
        #expect(detail.starIsLucky)
        #expect(detail.ganzhiSummary == "丙午(马)年 丁酉月 庚子日")
    }

    @Test func recommendationsAndAvoidancesComeFromTyme() throws {
        let day = try #require(CalendarEngine.day(year: 2024, month: 6, day: 26))
        let detail = try #require(CalendarEngine.almanac(for: day))
        #expect(detail.recommends == ["嫁娶", "祭祀", "理发", "作灶", "修饰垣墙", "平治道涂", "整手足甲", "沐浴", "冠笄"])
        #expect(detail.avoids == ["破土", "出行", "栽种"])
        #expect(Set(detail.luckyGods).isDisjoint(with: Set(detail.unluckyGods)))
    }

    @Test func twelveHoursDoNotIncludeNextDaysLateZi() throws {
        let day = try #require(CalendarEngine.day(year: 2026, month: 9, day: 23))
        let detail = try #require(CalendarEngine.almanac(for: day))
        #expect(detail.hours.count == 12)
        #expect(detail.hours.map(\.branch) == ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"])
        #expect(detail.hours.map(\.stem) == ["丙", "丁", "戊", "己", "庚", "辛", "壬", "癸", "甲", "乙", "丙", "丁"])
        #expect(detail.hours.map(\.isLucky) == [true, true, false, true, false, false, true, false, true, true, false, false])
        #expect(Set(detail.hours.map(\.id)).count == 12)
    }

    @Test(arguments: [(1900, 1, 1), (2023, 3, 22), (2100, 12, 31)])
    func supportedBoundariesAndLunarLeapMonth(_ date: (Int, Int, Int)) throws {
        let day = try #require(CalendarEngine.day(year: date.0, month: date.1, day: date.2))
        let detail = try #require(CalendarEngine.almanac(for: day))
        #expect(detail.hours.count == 12)
        #expect(detail.sound.isEmpty == false)
        #expect(detail.pengZu.count == 2)
    }
}
