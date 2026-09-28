// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct CalendarEnhancementTests {
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    @Test func menuBarPresetsShowWeekdayAndFullLunarDate() throws {
        var preferences = CalendarPreferences()
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-28T16:30:00Z"))
        #expect(preferences.title(at: date, locale: Locale(identifier: "en_US"), timeZone: zone).contains("Tue"))
        let locale = Locale(identifier: "zh_Hans_CN")
        preferences.display = .lunar
        #expect(preferences.title(at: date, locale: locale, timeZone: zone) == "八月十九")
        #expect(preferences.title(at: date, locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!) == "八月十八")
        preferences.display = .dateLunar
        let combined = preferences.title(at: date, locale: locale, timeZone: zone)
        #expect(combined.contains("29") && combined.contains("八月十九"))
    }

    @Test func lunarTitlePreservesMonthStartsAndLeapMonths() throws {
        let leap = try #require(ISO8601DateFormatter().date(from: "2025-07-25T04:00:00Z"))
        #expect(CalendarEngine.lunarDateTitle(at: leap, locale: Locale(identifier: "zh_Hans_CN"), timeZone: zone) == "闰六月初一")
        #expect(CalendarEngine.lunarDateTitle(at: leap, locale: Locale(identifier: "zh_Hant_TW"), timeZone: zone) == "閏六月初一")
        let newYear = try #require(ISO8601DateFormatter().date(from: "2026-02-17T04:00:00Z"))
        #expect(CalendarEngine.lunarDateTitle(at: newYear, locale: Locale(identifier: "zh_Hans_CN"), timeZone: zone) == "正月初一")
    }

    @Test(arguments: ["en_US", "en_GB", "zh_Hans_CN"])
    func customDateKeepsUserOrderAndSeparators(localeID: String) throws {
        var preferences = CalendarPreferences()
        preferences.display = .custom
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-28T04:00:00Z"))
        let locale = Locale(identifier: localeID)
        for (format, expected) in [("yyyy-MM-dd", "2026-09-28"), ("M月d日", "9月28日"),
                                   ("dd/MM", "28/09"), ("d.M.yy", "28.9.26")] {
            preferences.dateFormat = format
            #expect(preferences.isDateFormatValid)
            #expect(preferences.title(at: date, locale: locale, timeZone: zone) == expected)
        }
    }

    @Test(arguments: ["", "yyyy", "MM", "YYYY-MM-dd", "MM-DD", "HH:mm:ss", "MM/dd '", "MM\ndd"])
    func invalidCustomDatesUseReadableFallback(format: String) throws {
        var preferences = CalendarPreferences()
        preferences.display = .custom
        preferences.dateFormat = format
        #expect(!preferences.isDateFormatValid)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-28T04:00:00Z"))
        #expect(preferences.title(at: date, locale: Locale(identifier: "en_US"), timeZone: zone) == "09/28")
    }

    @Test func retiredDisplayModesDecodeWithoutDiscardingOtherPreferences() throws {
        let icon = try JSONDecoder().decode(CalendarPreferences.self,
            from: Data(#"{"display":"dayNumber","showEvents":true}"#.utf8))
        #expect(icon.display == .standard)
        #expect(icon.showEvents)
        let compact = try JSONDecoder().decode(CalendarPreferences.self, from: Data(#"{"display":"compact"}"#.utf8))
        #expect(compact.display == .custom)
        #expect(compact.dateFormat == "MM/dd")
        let custom = try JSONDecoder().decode(CalendarPreferences.self,
            from: Data(#"{"display":"custom","dateFormat":"d.M.yyyy","largeLunarText":true}"#.utf8))
        #expect(custom.display == .custom)
        #expect(custom.dateFormat == "d.M.yyyy")
        #expect(custom.largeLunarText)
    }

    @Test func calendarPreferencesKeepSafeDefaultsForOlderDocuments() throws {
        let old = try JSONDecoder().decode(CalendarPreferences.self, from: Data("{}".utf8))
        #expect(old == CalendarPreferences())
        #expect(!old.showEvents && !old.showReminders && !old.openOnHover)
        let future = try JSONDecoder().decode(CalendarPreferences.self, from: Data(#"{"display":"future"}"#.utf8))
        #expect(future.display == .standard)
    }

    @Test func displayPreferencesRoundTripWithoutSyncingLocalCalendarIDs() throws {
        let name = "CalendarEnhancementTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.calendarPreferences.display = .custom
        settings.calendarPreferences.dateFormat = "dd.MM.yyyy"
        settings.calendarPreferences.largeLunarText = true
        settings.calendarEventSourceIDs = ["local-private-id"]
        settings.calendarReminderSourceIDs = []
        let restored = AppSettings(defaults: defaults)
        #expect(restored.calendarPreferences == settings.calendarPreferences)
        #expect(restored.calendarReminderSourceIDs == [])
        let data = try JSONEncoder().encode(settings.exportDocument())
        #expect(!String(decoding: data, as: UTF8.self).contains("local-private-id"))
        settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
        #expect(settings.calendarPreferences.display == .custom)
        #expect(settings.calendarEventSourceIDs == ["local-private-id"])
    }

    @Test func allDayAndOvernightEventsExcludeTheirEndDay() throws {
        let calendar = CalendarEngine.gregorian(timeZone: zone)
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28)))
        let next = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let event = CalendarAgendaItem(id: "event", title: "", source: "", start: start, end: next,
                                      isAllDay: true, isReminder: false)
        #expect(event.occurs(on: start, calendar: calendar))
        #expect(!event.occurs(on: next, calendar: calendar))
        let overnight = CalendarAgendaItem(id: "night", title: "", source: "", start: next.addingTimeInterval(-1800),
                                          end: next.addingTimeInterval(1800), isAllDay: false, isReminder: false)
        #expect(overnight.occurs(on: start, calendar: calendar))
        #expect(overnight.occurs(on: next, calendar: calendar))
        let reminder = CalendarAgendaItem(id: "todo", title: "", source: "", start: next, end: next,
                                         isAllDay: false, isReminder: true)
        #expect(!reminder.occurs(on: start, calendar: calendar))
        #expect(reminder.occurs(on: next, calendar: calendar))
    }

    @Test func eventDayMatchingRespectsDSTInsteadOfFixed24Hours() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let calendar = CalendarEngine.gregorian(timeZone: zone)
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let next = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        #expect(next.timeIntervalSince(start) == 23 * 3600)
        let event = CalendarAgendaItem(id: "dst", title: "", source: "", start: next, end: next,
                                      isAllDay: false, isReminder: true)
        #expect(!event.occurs(on: start, calendar: calendar))
    }

    @Test func holidaySuggestionsBridgePublishedHolidaysUsingOnlyFutureWorkdays() throws {
        let today = try #require(CalendarEngine.day(year: 2026, month: 9, day: 23, timeZone: zone))
        let plan = try #require(CalendarEngine.holidayPlan(from: today.date, timeZone: zone))
        #expect(plan.daysUntil == 2)
        #expect(plan.totalDays == 3)
        let bridge = try #require(plan.leaveOptions.first { $0.leaveDates.count == 3 })
        #expect(bridge.totalDays == 13)
        let calendar = CalendarEngine.gregorian(timeZone: zone)
        #expect(bridge.leaveDates.map { calendar.component(.day, from: $0) } == [28, 29, 30])
        let during = try #require(CalendarEngine.day(year: 2026, month: 9, day: 26, timeZone: zone))
        let ongoing = try #require(CalendarEngine.holidayPlan(from: during.date, timeZone: zone))
        #expect(ongoing.daysUntil == 0)
        #expect(ongoing.leaveOptions.allSatisfy { $0.leaveDates.allSatisfy { $0 >= calendar.startOfDay(for: during.date) } })
        let unknown = try #require(CalendarEngine.day(year: 2027, month: 1, day: 1, timeZone: zone))
        #expect(CalendarEngine.holidayPlan(from: unknown.date, timeZone: zone) == nil)
    }

    @Test func makeupSaturdayIsCountedAsLeaveRatherThanAFreeWeekend() throws {
        let calendar = CalendarEngine.gregorian(timeZone: zone)
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let days = (0..<10).map { index in
            CalendarWorkday(date: calendar.date(byAdding: .day, value: index, to: today)!,
                            isWork: ![2, 3, 5].contains(index), holidayName: index == 2 ? "holiday" : nil)
        }
        let plan = try #require(CalendarHolidayPlan.make(days: days, today: today, calendar: calendar))
        #expect(plan.totalDays == 2)
        let option = try #require(plan.leaveOptions.first { $0.leaveDates.count == 1 })
        #expect(option.totalDays == 4)
        #expect(option.leaveDates == [days[4].date])
    }

    @Test(arguments: [CGFloat(10), CGFloat(500), CGFloat(1000)])
    func panelRemainsInsideShortNarrowScreen(_ anchorX: CGFloat) {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frame = StatusPanel.constrainedFrame(anchor: CGRect(x: anchorX, y: 320, width: 20, height: 20), visible: visible,
                                                preferredSize: CGSize(width: 560, height: 700))
        #expect(frame.minX >= visible.minX)
        #expect(frame.maxX <= visible.maxX)
        #expect(frame.minY >= visible.minY)
        #expect(frame.maxY <= visible.maxY)
    }

    @Test func calendarPopoverShrinksWithAvailableScreenSpace() {
        let desktop = CalendarPopoverSizing.fitting(visibleSize: CGSize(width: 1920, height: 1080))
        let laptop = CalendarPopoverSizing.fitting(visibleSize: CGSize(width: 1024, height: 700))
        #expect(desktop.width < 560)
        #expect(desktop.maxHeight <= 640)
        #expect(laptop.width < desktop.width)
        #expect(laptop.cellHeight < desktop.cellHeight)
        #expect(laptop.maxHeight <= 700 * 0.75)
    }
}
