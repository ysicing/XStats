// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
import WidgetData

@Test func snapshotRoundTripAndDisabledModules() throws {
    let suite = "WidgetSnapshotTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WidgetSnapshotStore(defaults: defaults)
    let now = Date()
    let snapshot = WidgetSnapshot(
        aiEnabled: true,
        quotas: [.init(provider: "codex", kind: "weekly", remainingPercent: 37, resetsAt: now.addingTimeInterval(60),
                       fetchedAt: now, isStale: false)],
        publicIPEnabled: true,
        addresses: [.init(family: "v4", ip: "203.0.113.1", countryCode: "CN", city: nil,
                          organization: nil, purityScore: 82, purityGrade: "A")],
        language: "japanese", calendarFirstWeekday: 1, showsLunar: false)
    #expect(store.save(snapshot))
    #expect(store.load() == snapshot)
    #expect(snapshot.currentQuotas(at: now).count == 1)
    #expect(snapshot.currentQuotas(at: now.addingTimeInterval(61)).isEmpty)

    var disabled = snapshot
    disabled.aiEnabled = false
    disabled.publicIPEnabled = false
    #expect(disabled.currentQuotas(at: now).isEmpty)
    #expect(disabled.visibleAddresses.isEmpty)
}

@Test func calendarSummaryUsesLocalCivilDayAndOldCacheStillDecodes() throws {
    let legacy = Data(#"{"aiEnabled":false,"quotas":[],"publicIPEnabled":false,"addresses":[],"language":"system","calendarFirstWeekday":2,"showsLunar":true}"#.utf8)
    let oldSnapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: legacy)
    #expect(oldSnapshot.calendarDays == nil)

    let day = WidgetSnapshot.CalendarSummary(dateKey: "2026-09-25", festivals: ["中秋节"],
                                             solarTerm: nil, schedule: .dayOff, holidayName: "中秋节",
                                             twelveStar: "除", isEcliptic: true,
                                             recommends: ["祭祀"], avoids: ["动土"])
    var snapshot = oldSnapshot
    snapshot.calendarDays = [day]
    let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-24T16:00:00Z"))
    var shanghai = Calendar(identifier: .gregorian)
    shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    #expect(snapshot.calendarSummary(for: instant, calendar: shanghai) == day)
    #expect(snapshot.calendarSummary(for: instant, calendar: utc) == nil)
    #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
}

@Test func tomorrowWorkAnswerDoesNotGuessWithoutHolidayCoverage() {
    #expect(WidgetSnapshot.CalendarSummary.Schedule.work.needsWork == true)
    #expect(WidgetSnapshot.CalendarSummary.Schedule.makeupWork.needsWork == true)
    #expect(WidgetSnapshot.CalendarSummary.Schedule.dayOff.needsWork == false)
    #expect(WidgetSnapshot.CalendarSummary.Schedule.unknown.needsWork == nil)
}
