// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SQLite3
import Testing
@testable import XStatsUI

struct WellnessActivityTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test func midnightSplitsFocusAndRestTime() {
        let midnight = Date(timeIntervalSince1970: 1_800_057_600)
        let today = calendar.startOfDay(for: midnight)
        let focus = WellnessActivity(kind: .focus, startedAt: today.addingTimeInterval(-60),
                                     endedAt: today.addingTimeInterval(60), completed: true)
        let rest = WellnessActivity(kind: .rest, startedAt: today, endedAt: today.addingTimeInterval(300), completed: true)
        let summary = WellnessSummary.make(activities: [focus, rest], at: today.addingTimeInterval(600), calendar: calendar)
        #expect(summary.today?.focusSeconds == 60)
        #expect(summary.days[5].focusSeconds == 60)
        #expect(summary.today?.focusCount == 1)
        #expect(summary.today?.restSeconds == 300)
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

    @Test func storePersistsRestAndRejectsOldOrInvalidRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("activity.sqlite")
        let now = Date(timeIntervalSince1970: 1_800_057_600)
        let store = WellnessActivityStore(url: path)
        let activity = WellnessActivity(kind: .rest, startedAt: now.addingTimeInterval(-60), endedAt: now, completed: true)
        try await store.record(activity, now: now)
        try await store.record(activity, now: now) // 同一事件重送不能多记一次。
        let old = WellnessActivity(kind: .focus, startedAt: now.addingTimeInterval(-91 * 86400),
                                   endedAt: now.addingTimeInterval(-91 * 86400 + 10), completed: true)
        try await store.record(old, now: now)
        let invalid = WellnessActivity(kind: .rest, startedAt: now, endedAt: now.addingTimeInterval(-1), completed: false)
        await #expect(throws: WellnessActivityStore.Failure.invalidActivity) { try await store.record(invalid, now: now) }
        let loaded = try await store.activities(since: .distantPast)
        #expect(loaded == [activity])
        let reopened = WellnessActivityStore(url: path)
        #expect(try await reopened.activities(since: .distantPast) == [activity])
        #expect(try await reopened.activities(since: .distantPast, now: now.addingTimeInterval(91 * 86400)).isEmpty)
        try await store.record(activity, now: now)
        try await store.record(activity, now: now)
        try await store.clear()
        #expect(try await store.activities(since: .distantPast).isEmpty)
    }
    @Test func legacyRemovedRowsAreIgnoredWithoutDeletingThem() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wellness-legacy-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = WellnessActivityStore(url: path)
        let now = Date(timeIntervalSince1970: 1000)
        let focus = WellnessActivity(kind: .focus, startedAt: now.addingTimeInterval(-30), endedAt: now, completed: true)
        try await store.record(focus, now: now)
        var database: OpaquePointer?
        try #require(sqlite3_open(path.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        INSERT INTO activity(id,kind,start,end,completed,part_of_rest) VALUES
        ('00000000-0000-0000-0000-000000000001','water',1000,1000,1,0),
        ('00000000-0000-0000-0000-000000000002','breathing',970,1000,1,0);
        """
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        #expect(try await store.activities(since: .distantPast) == [focus])
        var query: OpaquePointer?
        try #require(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM activity", -1, &query, nil) == SQLITE_OK)
        defer { sqlite3_finalize(query) }
        try #require(sqlite3_step(query) == SQLITE_ROW)
        #expect(sqlite3_column_int(query, 0) == 3)
    }

}
