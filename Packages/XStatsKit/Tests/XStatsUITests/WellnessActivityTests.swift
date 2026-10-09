// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

struct WellnessActivityTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test func midnightSplitsTimeAndBreathingInsideRestIsNotCountedTwice() {
        let midnight = Date(timeIntervalSince1970: 1_800_057_600)
        let today = calendar.startOfDay(for: midnight)
        let focus = WellnessActivity(kind: .focus, startedAt: today.addingTimeInterval(-60),
                                     endedAt: today.addingTimeInterval(60), completed: true)
        let rest = WellnessActivity(kind: .rest, startedAt: today, endedAt: today.addingTimeInterval(300), completed: true)
        var breath = WellnessActivity(kind: .breathing, startedAt: today, endedAt: today.addingTimeInterval(180), completed: true)
        breath.isPartOfRest = true
        let water = WellnessActivity(kind: .water, startedAt: today, endedAt: today, completed: true)
        let summary = WellnessSummary.make(activities: [focus, rest, breath, water], at: today.addingTimeInterval(600), calendar: calendar)
        #expect(summary.today?.focusSeconds == 60)
        #expect(summary.days[5].focusSeconds == 60)
        #expect(summary.today?.focusCount == 1)
        #expect(summary.today?.restSeconds == 300)
        #expect(summary.today?.breathingSeconds == 180)
        #expect(summary.today?.waterCount == 1)
    }

    @Test func trackerWritesOnlyTransitionsAndExcludesSuspendedTime() {
        var tracker = RestActivityTracker()
        let date = Date(timeIntervalSince1970: 1000)
        #expect(tracker.update(phase: .work, running: true, deadline: 60_000_000_000, now: 0, date: date) == nil)
        #expect(tracker.update(phase: .work, running: true, deadline: 60_000_000_000, now: 10_000_000_000, date: date) == nil)
        let stopped = tracker.finish(at: 20_000_000_000)
        #expect(stopped?.duration == 20 && stopped?.completed == false)
        #expect(tracker.finish(at: 100_000_000_000) == nil)
    }

    @Test func storePersistsWaterSupportsUndoAndRejectsOldOrInvalidRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("activity.sqlite")
        let now = Date(timeIntervalSince1970: 1_800_057_600)
        let store = WellnessActivityStore(url: path)
        let water = WellnessActivity(kind: .water, startedAt: now, endedAt: now, completed: true)
        try await store.record(water, now: now)
        try await store.record(water, now: now) // 同一事件重送不能多记一次。
        let old = WellnessActivity(kind: .focus, startedAt: now.addingTimeInterval(-91 * 86400),
                                   endedAt: now.addingTimeInterval(-91 * 86400 + 10), completed: true)
        try await store.record(old, now: now)
        let invalid = WellnessActivity(kind: .rest, startedAt: now, endedAt: now.addingTimeInterval(-1), completed: false)
        await #expect(throws: WellnessActivityStore.Failure.invalidActivity) { try await store.record(invalid, now: now) }
        let loaded = try await store.activities(since: .distantPast)
        #expect(loaded == [water])
        let reopened = WellnessActivityStore(url: path)
        #expect(try await reopened.activities(since: .distantPast) == [water])
        #expect(try await reopened.activities(since: .distantPast, now: now.addingTimeInterval(91 * 86400)).isEmpty)
        try await store.record(water, now: now)
        try await store.remove(water.id)
        #expect(try await store.activities(since: .distantPast).isEmpty)
        try await store.record(water, now: now)
        try await store.clear()
        #expect(try await store.activities(since: .distantPast).isEmpty)
    }
}
