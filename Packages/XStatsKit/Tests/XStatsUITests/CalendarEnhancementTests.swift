// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Localization
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct CalendarEnhancementTests {
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    @Test(arguments: [false, true], [false, true])
    func detachedCalendarMeasurementIncludesEnabledContent(showsDayDetails: Bool, showsHolidayOverview: Bool) async throws {
        let name = "CalendarMeasurementTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, calendarLocale: Locale(identifier: "zh_CN"))
        settings.calendarFeatures = [.lunar, .holidays, .festivals, .seasonalInfo]
        settings.calendarPreferences.showHolidayOverview = showsHolidayOverview
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-23T04:00:00Z"))
        let hosting = NSHostingView(rootView: CalendarPopover(referenceDate: date, showsDayDetails: showsDayDetails,
                                                              firstWeekday: settings.calendarFirstWeekday)
            .environment(model)
            .environment(\.isSnapshot, true))
        // StatusPanel 在挂载前测量；启用的卡片必须已计入高度，不能等 onAppear 后才补齐。
        let measured = hosting.fittingSize
        #expect(hosting.window == nil)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: measured),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(hosting.fittingSize.height - measured.height) < 1)
    }

    @Test func calendarLayoutDoesNotFeedOverflowBackIntoWindowSize() async throws {
        let name = "CalendarLayoutTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil,
                             aiUsageProviders: [], aiQuotaProviders: [])
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-29T04:00:00Z"))
        var overflowReports = 0
        let reporter = PopoverHeightReporter { _ in overflowReports += 1 }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 460, height: 380),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for details in [false, true] {
            let hosting = NSHostingView(rootView: CalendarPopover(referenceDate: date, showsDayDetails: details, firstWeekday: model.settings.calendarFirstWeekday)
                .environment(model)
                .environment(\.reportPopoverHeight, reporter))
            window.contentView = hosting
            window.orderFrontRegardless()
            for height in [380.0, 640.0, 400.0] {
                window.setContentSize(NSSize(width: 460, height: height))
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                #expect(abs(hosting.bounds.height - height) < 1)
            }
        }
        // 内容溢出应留在滚动区域内，不能再反向驱动 StatusPanel.setFrame。
        #expect(overflowReports == 0)
    }

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

    @Test(arguments: ["en_CN", "en_US", "ja_JP", "ko_KR", "de_DE", "es_ES", "fr_FR", "ar_SA"])
    func manualLunarDisplaySurvivesEveryLanguage(localeID: String) throws {
        let locale = Locale(identifier: localeID)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-28T04:00:00Z"))
        let expected = try #require(CalendarEngine.lunarDateTitle(at: date, locale: locale, timeZone: zone))
        let standard = CalendarPreferences().title(at: date, locale: locale, timeZone: zone)
        var preferences = CalendarPreferences()
        preferences.display = .lunar
        #expect(preferences.title(at: date, locale: locale, timeZone: zone) == expected)
        #expect(preferences.title(at: date, locale: locale, timeZone: zone) != standard)
        preferences.display = .dateLunar
        #expect(preferences.title(at: date, locale: locale, timeZone: zone).contains(expected))
        let restored = try JSONDecoder().decode(CalendarPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored.display == .dateLunar)
        #expect(restored.title(at: date, locale: locale, timeZone: zone) == preferences.title(at: date, locale: locale, timeZone: zone))
    }

    @Test(arguments: [CalendarPreferences.Display.lunar, .dateLunar])
    func disablingLunarDisplayPreservesSavedPresentation(display: CalendarPreferences.Display) throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-28T04:00:00Z"))
        let locale = Locale(identifier: "en_US")
        let standard = CalendarPreferences().title(at: date, locale: locale, timeZone: zone)
        var preferences = CalendarPreferences()
        preferences.display = display
        preferences.largeLunarText = true
        preferences.strongerLunarText = true
        let enabled = preferences.title(at: date, locale: locale, timeZone: zone)
        #expect(preferences.title(at: date, locale: locale, timeZone: zone, showsLunar: false) == standard)
        let restored = try JSONDecoder().decode(CalendarPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored.display == display)
        #expect(restored.largeLunarText && restored.strongerLunarText)
        #expect(restored.title(at: date, locale: locale, timeZone: zone, showsLunar: true) == enabled)
    }

    @Test(arguments: Array(1...7))
    func monthGridAndWidgetHonorEveryWeekStart(firstWeekday: Int) throws {
        let days = CalendarEngine.month(year: 2026, month: 9, firstWeekday: firstWeekday, timeZone: zone)
        let first = try #require(days.first)
        #expect(days.count == 42 && first.weekday == firstWeekday)
        let summary = CalendarEngine.widgetMonthSummary(year: 2026, month: 9, firstWeekday: firstWeekday,
                                                        features: [], timeZone: zone)
        #expect(summary.firstWeekday == firstWeekday)
        #expect(summary.days.first?.dateKey == first.id)
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

    @Test(arguments: [true, false])
    func retiredAlmanacTogglePreservesOtherPreferences(enabled: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: ["showAlmanac": enabled, "display": "lunar", "showEvents": true])
        let preferences = try JSONDecoder().decode(CalendarPreferences.self, from: data)
        #expect(preferences.display == .lunar && preferences.showEvents)
        let exported = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        #expect(exported["showAlmanac"] == nil)
    }

    @Test func calendarPreferencesKeepSafeDefaultsForOlderDocuments() throws {
        let old = try JSONDecoder().decode(CalendarPreferences.self, from: Data("{}".utf8))
        #expect(old == CalendarPreferences(locale: Locale(identifier: "zh_CN")))
        #expect(old.showHolidayOverview)
        #expect(!old.showEvents && !old.showReminders && !old.openOnHover)
        let future = try JSONDecoder().decode(CalendarPreferences.self, from: Data(#"{"display":"future"}"#.utf8))
        #expect(future.display == .standard)
    }

    @Test(arguments: ["en_US", "en_CN", "zh_Hans_CN", "zh_Hant_CN", "zh_Hant_TW", "zh_Hant_HK", "zh_Hant_MO",
                      "zh_Hans_SG", "ja_JP", "ko_KR", "ar_SA", "fr_FR"])
    func freshCalendarDefaultsFollowRegionAndRemainStable(localeID: String) throws {
        let name = "CalendarRegionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let locale = Locale(identifier: localeID)
        let mainland = locale.region?.identifier == "CN"
        let expected: Set<CalendarFeature> = mainland ? [.lunar, .holidays, .festivals, .seasonalInfo] : []
        let settings = AppSettings(defaults: defaults, calendarLocale: locale)
        #expect(settings.calendarFeatures == expected)
        #expect(settings.calendarPreferences.showHolidayOverview == mainland)
        let day = try #require(CalendarEngine.day(year: 2026, month: 9, day: 25, timeZone: zone))
        #expect(CalendarEngine.widgetSummary(for: day, features: settings.calendarFeatures).twelveStar != nil)
        #expect(settings.calendarFeatures.contains(.seasonalInfo) == mainland)

        // 更改地区不应重置首次保存的默认值，明确关闭的选项和空集合也须保留。
        let otherRegion = Locale(identifier: mainland ? "zh_TW" : "en_CN")
        let restored = AppSettings(defaults: defaults, calendarLocale: otherRegion)
        #expect(restored.calendarFeatures == expected)
        #expect(restored.calendarPreferences == settings.calendarPreferences)
        settings.calendarFeatures = []
        settings.calendarPreferences.showHolidayOverview = false
        let disabled = AppSettings(defaults: defaults, calendarLocale: Locale(identifier: "zh_CN"))
        #expect(disabled.calendarFeatures.isEmpty)
        #expect(!disabled.calendarPreferences.showHolidayOverview)
    }

    @Test(arguments: [true, false])
    func existingInstallKeepsLegacyCalendarDefaultsInEveryRegion(calendarEnabled: Bool) throws {
        let name = "CalendarUpgradeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // 旧版只写入过日历开关，未保存任何日历选项。
        defaults.set(calendarEnabled, forKey: "calendarEnabled")
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        let settings = AppSettings(defaults: defaults, calendarLocale: Locale(identifier: "en_US"), calendar: calendar)
        #expect(settings.calendarEnabled == calendarEnabled)
        #expect(settings.calendarFeatures == [.lunar, .holidays, .festivals, .seasonalInfo])
        #expect(settings.calendarPreferences.showHolidayOverview)
        #expect(settings.calendarFirstWeekday == 2)
        // 沿用的默认值在首次启动时保存，之后地区或系统周起始日变化不再影响。
        let reloaded = AppSettings(defaults: defaults, calendarLocale: Locale(identifier: "ja_JP"), calendar: calendar)
        #expect(reloaded.calendarFeatures == settings.calendarFeatures)
        #expect(reloaded.calendarPreferences == settings.calendarPreferences)
        #expect(reloaded.calendarFirstWeekday == 2)
    }

    @Test(arguments: Array(1...7))
    func weekStartUsesSystemDefaultOnceAndPreservesManualChoice(firstWeekday: Int) throws {
        let name = "CalendarWeekStartTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = firstWeekday
        let settings = AppSettings(defaults: defaults, calendarLocale: Locale(identifier: "en_US"), calendar: calendar)
        #expect(settings.calendarFirstWeekday == firstWeekday)
        #expect(defaults.integer(forKey: "calendarFirstWeekday") == firstWeekday)

        calendar.firstWeekday = firstWeekday % 7 + 1
        let restored = AppSettings(defaults: defaults, calendarLocale: Locale(identifier: "zh_CN"), calendar: calendar)
        #expect(restored.calendarFirstWeekday == firstWeekday)
        settings.calendarFirstWeekday = 3
        #expect(AppSettings(defaults: defaults, calendar: calendar).calendarFirstWeekday == 3)
    }

    @Test(arguments: Array(1...7))
    func backupsRestoreEveryWeekStartAndRejectInvalidValues(firstWeekday: Int) throws {
        let name = "CalendarWeekBackupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 7
        defaults.set(99, forKey: "calendarFirstWeekday")
        let settings = AppSettings(defaults: defaults, calendar: calendar)
        #expect(settings.calendarFirstWeekday == 7)
        #expect(defaults.integer(forKey: "calendarFirstWeekday") == 7)

        settings.calendarFirstWeekday = firstWeekday
        let document = try JSONDecoder().decode(SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
        settings.calendarFirstWeekday = firstWeekday % 7 + 1
        settings.apply(document)
        #expect(settings.calendarFirstWeekday == firstWeekday)
        var invalid = SettingsDocument()
        invalid.calendarFirstWeekday = 99
        settings.apply(invalid)
        #expect(settings.calendarFirstWeekday == firstWeekday)
        settings.apply(SettingsDocument())
        #expect(settings.calendarFirstWeekday == firstWeekday)
    }

    @Test func existingCalendarChoicesAndBackupsSurviveRegionalDefaults() throws {
        let name = "CalendarExistingRegionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["lunar", "holidays", "dogDays"], forKey: "calendarFeatures")
        defaults.set(Data(#"{"display":"lunar","showHolidayOverview":true}"#.utf8), forKey: "calendarPreferences")
        let settings = AppSettings(defaults: defaults, calendarLocale: Locale(identifier: "en_US"))
        #expect(settings.calendarFeatures == [.lunar, .holidays, .seasonalInfo])
        #expect(settings.calendarPreferences.display == .lunar)
        #expect(settings.calendarPreferences.showHolidayOverview)
        let backup = try JSONDecoder().decode(SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
        settings.calendarFeatures = []
        settings.calendarPreferences.showHolidayOverview = false
        settings.apply(backup)
        #expect(settings.calendarFeatures == [.lunar, .holidays, .seasonalInfo])
        #expect(settings.calendarPreferences.showHolidayOverview)
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

    @Test func overnightEventShowsContinuationInsteadOfYesterdaysStartTime() throws {
        let calendar = CalendarEngine.gregorian(timeZone: zone)
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 22)))
        let nextDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 29)))
        let night = CalendarAgendaItem(id: "night", title: "", source: "", start: start,
                                       end: start.addingTimeInterval(4 * 3600), isAllDay: false, isReminder: false)
        let first = night.timeLabel(on: start, calendar: calendar)
        #expect(first != tr("续") && first != tr("全天"), "start day shows the start time: \(first)")
        #expect(night.timeLabel(on: nextDay, calendar: calendar) == tr("续"))
        let allDay = CalendarAgendaItem(id: "all", title: "", source: "", start: nextDay,
                                        end: nextDay.addingTimeInterval(86_400), isAllDay: true, isReminder: false)
        #expect(allDay.timeLabel(on: nextDay, calendar: calendar) == tr("全天"))
    }

    @Test func refreshingUnchangedAuthorizationDoesNotRestartTheQuery() async throws {
        let agenda = CalendarAgendaController()
        let before = agenda.revision
        // 打开面板、应用激活都会调用；授权没变时不能改动查询的 id，否则刚开始的查询会被取消重来
        agenda.refreshAuthorization()
        agenda.refreshAuthorization()
        #expect(agenda.revision == before)
        for _ in 0..<100 { agenda.storeChanged() }
        #expect(agenda.revision == before, "a burst of store notifications should be coalesced")
        for _ in 0..<30 {
            if agenda.revision != before { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(agenda.revision == before + 1, "calendar content changes must trigger a reload")
        agenda.storeChanged()
        agenda.clear()
        try await Task.sleep(for: .milliseconds(500))
        #expect(agenda.revision == before + 1, "closing the panel must cancel scheduled refreshes")
    }

    @Test func repeatedMonthCalculationReusesStorageAndInvalidatesForCalendarChanges() throws {
        let first = CalendarEngine.month(year: 2026, month: 9, firstWeekday: 2, timeZone: zone)
        let repeated = CalendarEngine.month(year: 2026, month: 9, firstWeekday: 2, timeZone: zone)
        // 两份结果同时存活：共享 CoW 存储证明测量视图和实际视图没有再次生成 42 天数据。
        first.withUnsafeBufferPointer { a in
            repeated.withUnsafeBufferPointer { b in #expect(a.baseAddress == b.baseAddress) }
        }
        let sunday = CalendarEngine.month(year: 2026, month: 9, firstWeekday: 1, timeZone: zone)
        #expect(sunday.first?.id == "2026-08-30")
        let utc = CalendarEngine.month(year: 2026, month: 9, firstWeekday: 2, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(utc.map(\.id) == first.map(\.id))
        #expect(utc.first?.date != first.first?.date)
        #expect(CalendarEngine.month(year: 2026, month: 10, firstWeekday: 2, timeZone: zone).first?.id == "2026-09-28")
        let evicted = CalendarEngine.month(year: 2026, month: 9, firstWeekday: 2, timeZone: zone)
        #expect(evicted == first)
        first.withUnsafeBufferPointer { a in
            evicted.withUnsafeBufferPointer { b in #expect(a.baseAddress != b.baseAddress) }
        }
    }

    @Test(arguments: [3, 11])
    func agendaMarkersMatchEventSemanticsAcrossDST(month: Int) throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let calendar = CalendarEngine.gregorian(timeZone: zone)
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: 1)))
        let end = try #require(calendar.date(byAdding: .day, value: 42, to: start))
        let query = CalendarAgendaQuery(start: start, end: end, events: true, reminders: true,
                                       eventIDs: nil, reminderIDs: nil, revision: 0, timeZone: zone)
        // 覆盖跨月、跨午夜、零时长、提醒、结束边界及窗口外数据，与旧逐日判断逐一对照。
        for offset in [-10, -1, 0, 7, 8, 30, 41, 42, 50] {
            let date = try #require(calendar.date(byAdding: .day, value: offset, to: start))
            for duration in [-3600.0, 0, 3600, 86_400, 4_000_000] {
                for reminder in [false, true] {
                    let item = CalendarAgendaItem(id: "test", title: "", source: "", start: date,
                                                 end: date.addingTimeInterval(duration), isAllDay: false, isReminder: reminder)
                    let result = CalendarAgendaResult(items: [item], query: query)
                    for dayIndex in 0..<42 {
                        let day = try #require(calendar.date(byAdding: .day, value: dayIndex, to: start))
                        #expect(result.markedDays.contains(day) == item.occurs(on: day, calendar: calendar))
                    }
                    #expect(result.markedDays.count <= 42)
                    #expect(result.markedDays.allSatisfy { $0 >= start && $0 < end })
                }
            }
        }
    }

    @Test(arguments: [("America/Havana", 2026, 3, 7), ("America/Sao_Paulo", 2018, 11, 3)])
    func agendaMarkersRemainAtDayStartAfterMidnightDST(_ sample: (String, Int, Int, Int)) throws {
        let zone = try #require(TimeZone(identifier: sample.0))
        let calendar = CalendarEngine.gregorian(timeZone: zone)
        // 每个日期独立求日界线，不能沿用待测算法按前一天的小时递增。
        let days = try (0..<5).map { offset in
            let noon = try #require(calendar.date(from: DateComponents(year: sample.1, month: sample.2,
                                                                      day: sample.3 + offset, hour: 12)))
            return calendar.startOfDay(for: noon)
        }
        #expect(calendar.component(.hour, from: days[1]) == 1)
        #expect(calendar.component(.hour, from: days[2]) == 0)
        let query = CalendarAgendaQuery(start: days[0], end: days[4], events: true, reminders: false,
                                       eventIDs: nil, reminderIDs: nil, revision: 0, timeZone: zone)
        let item = CalendarAgendaItem(id: "midnight-dst", title: "", source: "", start: days[0],
                                     end: days[4], isAllDay: true, isReminder: false)
        let result = CalendarAgendaResult(items: [item], query: query)
        #expect(result.markedDays == Set(days.prefix(4)))
        #expect(!result.markedDays.contains(days[4]), "event end remains exclusive")
    }

    @Test func unsupportedDisplayedYearDoesNotReuseCurrentHolidayPlan() throws {
        let today = try #require(CalendarEngine.day(year: 2026, month: 9, day: 23, timeZone: zone))
        let current = try #require(CalendarEngine.holidayPlan(from: today.date, timeZone: zone))
        #expect(!CalendarEngine.hasHolidayData(year: 2027))
        #expect(CalendarEngine.holidayPlan(from: today.date, timeZone: zone, displayedYear: 2027) == nil)
        // 返回已有数据的年份后，仍可复用当前日期的有效概览。
        let restored = try #require(CalendarEngine.holidayPlan(from: today.date, timeZone: zone, displayedYear: 2026))
        #expect(restored.start == current.start)
        let month = CalendarEngine.widgetMonthSummary(year: 2027, month: 9, firstWeekday: 2,
                                                      features: [.holidays], timeZone: zone)
        #expect(month.days.allSatisfy { $0.holidayName == nil && $0.isWork == nil })
    }

    @Test func holidayPlanCacheStillFollowsDayAndTimeZone() throws {
        let before = try #require(CalendarEngine.day(year: 2026, month: 9, day: 23, timeZone: zone))
        let first = try #require(CalendarEngine.holidayPlan(from: before.date, timeZone: zone))
        let repeated = try #require(CalendarEngine.holidayPlan(from: before.date.addingTimeInterval(3600), timeZone: zone))
        #expect(repeated.daysUntil == first.daysUntil && repeated.start == first.start)
        // 换日或换时区都不能复用上一次的结果
        let later = try #require(CalendarEngine.day(year: 2026, month: 9, day: 24, timeZone: zone))
        #expect(try #require(CalendarEngine.holidayPlan(from: later.date, timeZone: zone)).daysUntil == first.daysUntil - 1)
        let utc = TimeZone(secondsFromGMT: 0)!
        let utcPlan = try #require(CalendarEngine.holidayPlan(from: before.date, timeZone: utc))
        #expect(utcPlan.start != first.start, "a different time zone must be recomputed")
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
