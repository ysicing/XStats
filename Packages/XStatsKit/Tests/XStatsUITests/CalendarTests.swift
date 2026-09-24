// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct CalendarTests {
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    @Test func monthGridIncludesLeapDayAndAdjacentMonths() throws {
        let days = CalendarEngine.month(year: 2024, month: 2, firstWeekday: 2, timeZone: zone)
        #expect(days.count == 42)
        #expect(days.first?.id == "2024-01-29")
        #expect(days.last?.id == "2024-03-10")
        #expect(days.filter { $0.month == 2 }.count == 29)
        let sunday = CalendarEngine.month(year: 2024, month: 2, firstWeekday: 1, timeZone: zone)
        #expect(sunday.first?.id == "2024-01-28")
    }

    @Test func lunarLeapMonthAndFestivalPriority() throws {
        let leap = try #require(CalendarEngine.day(year: 2023, month: 3, day: 22, timeZone: zone))
        #expect(leap.lunarLabel == "闰二月")
        let newYear = try #require(CalendarEngine.day(year: 2026, month: 2, day: 17, timeZone: zone))
        #expect(newYear.festivals.contains("春节"))
        #expect(newYear.subtitle(features: [.lunar, .festivals]) == "春节")
        #expect(newYear.subtitle(features: [.lunar]) == "正月")
        #expect(newYear.subtitle(features: []) == "")
    }

    @Test func restAndMakeupWorkAreDistinct() throws {
        let rest = try #require(CalendarEngine.day(year: 2026, month: 9, day: 25, timeZone: zone))
        let work = try #require(CalendarEngine.day(year: 2026, month: 9, day: 20, timeZone: zone))
        #expect(rest.holiday?.isWork == false)
        #expect(work.holiday?.isWork == true)
        #expect(CalendarEngine.hasHolidayData(year: 2026))
        #expect(CalendarEngine.hasHolidayData(year: 2099) == false)
    }

    @Test func widgetSummaryKeepsTomorrowScheduleAndAlmanacSeparate() throws {
        let work = try #require(CalendarEngine.day(year: 2026, month: 9, day: 20, timeZone: zone))
        let holiday = try #require(CalendarEngine.day(year: 2026, month: 9, day: 25, timeZone: zone))
        let holidayExtension = try #require(CalendarEngine.day(year: 2026, month: 10, day: 2, timeZone: zone))
        let weekend = try #require(CalendarEngine.day(year: 2026, month: 9, day: 26, timeZone: zone))
        let adjustedDayOff = try #require(CalendarEngine.day(year: 2026, month: 10, day: 5, timeZone: zone))
        let ordinary = try #require(CalendarEngine.day(year: 2026, month: 9, day: 24, timeZone: zone))
        let unknown = try #require(CalendarEngine.day(year: 2027, month: 1, day: 4, timeZone: zone))

        #expect(CalendarEngine.widgetSummary(for: work).schedule == .makeupWork)
        #expect(CalendarEngine.widgetSummary(for: holiday).schedule.rawValue == "holiday")
        #expect(CalendarEngine.widgetSummary(for: holidayExtension).schedule.rawValue == "holiday")
        #expect(CalendarEngine.widgetSummary(for: weekend).schedule.rawValue == "weekend")
        #expect(CalendarEngine.widgetSummary(for: adjustedDayOff).schedule.rawValue == "makeupDayOff")
        #expect(CalendarEngine.widgetSummary(for: ordinary).schedule == .work)
        #expect(CalendarEngine.widgetSummary(for: unknown).schedule == .unknown)
        #expect(CalendarEngine.widgetSummary(for: holiday).festivals.contains("中秋节"))
        #expect(CalendarEngine.widgetSummary(for: holiday).recommends.isEmpty == false)
    }

    @Test func official2026ScheduleSeparatesStatutoryWeekendAndAdjustedRest() throws {
        let cases: [(Int, Int, String)] = [
            (1, 2, "makeupDayOff"),
            (2, 18, "holiday"),
            (2, 20, "makeupDayOff"),
            (4, 5, "holiday"),
            (4, 6, "makeupDayOff"),
            (5, 2, "holiday"),
            (10, 3, "holiday"),
            (10, 4, "weekend")
        ]
        for (month, day, expected) in cases {
            let date = try #require(CalendarEngine.day(year: 2026, month: month, day: day, timeZone: zone))
            #expect(CalendarEngine.widgetSummary(for: date).schedule.rawValue == expected)
        }
    }

    @Test func termsAndSeasonalBoundaries() throws {
        #expect(CalendarEngine.day(year: 2026, month: 9, day: 23, timeZone: zone)?.solarTerm == "秋分")
        #expect(CalendarEngine.day(year: 2026, month: 9, day: 24, timeZone: zone)?.solarTerm == nil)
        #expect(CalendarEngine.day(year: 2024, month: 6, day: 10, timeZone: zone)?.plumRain == nil)
        #expect(CalendarEngine.day(year: 2024, month: 6, day: 11, timeZone: zone)?.plumRain == "入梅第1天")
        #expect(CalendarEngine.day(year: 2024, month: 7, day: 6, timeZone: zone)?.plumRain == "出梅")
        #expect(CalendarEngine.day(year: 2024, month: 7, day: 7, timeZone: zone)?.plumRain == nil)
        #expect(CalendarEngine.day(year: 2012, month: 8, day: 8, timeZone: zone)?.dogDays == "末伏第2天")
    }

    @Test func optionalCalendarsHandleUnsupportedDates() throws {
        let date = try #require(CalendarEngine.day(year: 2026, month: 5, day: 13, timeZone: zone))
        let details = CalendarEngine.additionalCalendars(for: date, features: [.hijri, .tibetan])
        #expect(details.first { $0.feature == .hijri }?.value == "1447年都尔喀尔德月26日")
        #expect(details.first { $0.feature == .tibetan }?.value != nil)
        let early = try #require(CalendarEngine.day(year: 1900, month: 1, day: 1, timeZone: zone))
        #expect(CalendarEngine.additionalCalendars(for: early, features: [.tibetan]).first?.isUnavailable == true)
        let late = try #require(CalendarEngine.day(year: 2100, month: 1, day: 1, timeZone: zone))
        #expect(CalendarEngine.additionalCalendars(for: late, features: [.tibetan]).first?.isUnavailable == true)
        #expect(CalendarEngine.additionalCalendars(for: date, features: []).isEmpty)
    }

    @Test(arguments: [(1951, 1, 7, true), (1951, 1, 8, false), (2051, 2, 11, false), (2051, 2, 12, true)])
    func tibetanCoverageBoundaries(_ sample: (Int, Int, Int, Bool)) throws {
        let day = try #require(CalendarEngine.day(year: sample.0, month: sample.1, day: sample.2, timeZone: zone))
        let detail = try #require(CalendarEngine.additionalCalendars(for: day, features: [.tibetan]).first)
        #expect(detail.isUnavailable == sample.3)
    }

    @Test func invalidDatesAndNavigationLimits() {
        #expect(CalendarEngine.day(year: 2026, month: 2, day: 30, timeZone: zone) == nil)
        #expect(CalendarEngine.month(year: 2026, month: 13, firstWeekday: 2, timeZone: zone).isEmpty)
        #expect(CalendarMonth(year: 2026, month: 12).shifted(by: 1) == CalendarMonth(year: 2027, month: 1))
        #expect(CalendarMonth(year: 1900, month: 1).shifted(by: -1) == nil)
        #expect(CalendarMonth(year: 2100, month: 12).shifted(by: 1) == nil)
    }

    @Test func localDayChangesAcrossMidnightAndTimeZones() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-23T16:00:00Z"))
        #expect(CalendarEngine.today(at: instant, timeZone: zone)?.id == "2026-09-24")
        #expect(CalendarEngine.today(at: instant, timeZone: TimeZone(secondsFromGMT: 0)!)?.id == "2026-09-23")
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let days = CalendarEngine.month(year: 2026, month: 3, firstWeekday: 2, timeZone: losAngeles)
        #expect(Set(days.map(\.id)).count == 42)
    }

    @Test func historicalSelectionKeepsCivilDateAfterTimeZoneChange() throws {
        let old = try #require(CalendarEngine.day(year: 2024, month: 3, day: 22, timeZone: zone))
        let newZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let month = CalendarMonth(year: 2024, month: 3)
        let selected = try #require(CalendarEngine.selection(old, in: month, timeZone: newZone))
        #expect(selected.id == old.id)
        #expect(selected.lunarSummary == old.lunarSummary)
        #expect(selected.date != old.date)
        let parts = CalendarEngine.gregorian(timeZone: newZone).dateComponents([.day, .hour], from: selected.date)
        #expect(parts.day == 22)
        #expect(parts.hour == 12)
        #expect(CalendarEngine.selection(old, in: CalendarMonth(year: 2024, month: 4), timeZone: newZone)?.id == "2024-04-01")
    }

    @Test func preferencesPersistAndRoundTripWhileOldBackupsPreserveThem() throws {
        let name = "CalendarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.calendarEnabled == false)
        #expect(settings.calendarFeatures == CalendarFeature.defaults)
        settings.calendarEnabled = true
        settings.calendarFeatures = [.hijri, .ganzhi]
        settings.calendarFirstWeekday = 1
        let restored = AppSettings(defaults: defaults)
        #expect(restored.calendarEnabled)
        #expect(restored.calendarFeatures == [.hijri, .ganzhi])
        #expect(restored.calendarFirstWeekday == 1)
        let doc = try JSONDecoder().decode(SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
        restored.calendarFeatures = []
        restored.apply(doc)
        #expect(restored.calendarFeatures == [.hijri, .ganzhi])
        restored.apply(SettingsDocument())
        #expect(restored.calendarEnabled)
        #expect(restored.calendarFeatures == [.hijri, .ganzhi])
        var invalid = SettingsDocument()
        invalid.calendarFeatures = ["hijri", "future-feature"]
        invalid.calendarFirstWeekday = 99
        restored.apply(invalid)
        #expect(restored.calendarFeatures == [.hijri])
        #expect(restored.calendarFirstWeekday == 1)
    }
}
