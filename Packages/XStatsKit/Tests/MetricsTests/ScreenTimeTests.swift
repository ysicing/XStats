// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Metrics
import Testing

@Suite struct ScreenTimeTests {
    private var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        shanghai.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func splitAssignsEachSideOfMidnightToItsOwnDay() {
        let parts = ScreenTime.split(from: date(25, 23, 30), to: date(26, 0, 45), calendar: shanghai)
        #expect(parts.count == 2)
        #expect(parts[0].day == date(25, 0) && parts[0].seconds == 30 * 60)
        #expect(parts[1].day == date(26, 0) && parts[1].seconds == 45 * 60)
        #expect(ScreenTime.split(from: date(26, 10), to: date(26, 10), calendar: shanghai).isEmpty)
        #expect(ScreenTime.split(from: date(26, 11), to: date(26, 10), calendar: shanghai).isEmpty)
    }

    @Test func powerLogPairsDisplayOnWithTheNextOff() throws {
        let log = """
        2026-09-24 07:00:00 +0800 Notification        \tDisplay is turned off
        2026-09-24 09:00:00 +0800 Notification        \tDisplay is turned on
        2026-09-24 09:30:00 +0800 Notification        \tDisplay is turned on
        2026-09-24 11:00:00 +0800 Sleep               \tEntering Sleep state due to 'Idle Sleep'
        2026-09-24 11:00:05 +0800 Notification        \tDisplay is turned off
        2026-09-25 23:00:00 +0800 Notification        \tDisplay is turned on
        2026-09-26 01:00:00 +0800 Notification        \tDisplay is turned off
        2026-09-26 09:00:00 +0800 Notification        \tDisplay is turned on
        garbage line without a timestamp Display is turned on
        """
        let now = date(26, 10)
        let intervals = ScreenTime.displayIntervals(powerLog: log, now: now)
        // 开头孤立的 off 无从配对；重复的 on 不另起一段；末尾仍亮着的截止到 now
        #expect(intervals == [
            DateInterval(start: date(24, 9), end: date(24, 11, 0).addingTimeInterval(5)),
            DateInterval(start: date(25, 23), end: date(26, 1)),
            DateInterval(start: date(26, 9), end: now),
        ])
        #expect(ScreenTime.logStart(powerLog: log) == date(24, 7))
        let totals = ScreenTime.totals(of: intervals, calendar: shanghai)
        #expect(totals[date(24, 0)] == TimeInterval(2 * 3600 + 5))
        #expect(totals[date(25, 0)] == TimeInterval(3600))
        #expect(totals[date(26, 0)] == TimeInterval(3600 + 3600))
    }

    @Test func clearBoundaryPersistsAndBlocksOldEstimates() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-time-clear-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let database = try HistoryDatabase(url: url)
        await database.seedScreenTime(3600, day: date(24, 0))
        await database.clear(at: date(25, 12))

        let reopened = try HistoryDatabase(url: url)
        await reopened.seedScreenTime(3600, day: date(24, 0))
        await reopened.seedScreenTime(3600, day: date(25, 0))
        await reopened.seedScreenTime(1800, day: date(26, 0))
        await reopened.addScreenTime(60, day: date(25, 0))
        #expect(await reopened.screenTime(from: date(24, 0), to: date(27, 0)) == [
            ScreenTimeDay(day: date(25, 0), seconds: 60, estimated: false),
            ScreenTimeDay(day: date(26, 0), seconds: 1800, estimated: true)
        ])
    }

    @Test func databaseAccumulatesLiveTimeAndNeverOverwritesItWithEstimates() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-time-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let database = try HistoryDatabase(url: url)
        let day1 = date(24, 0), day2 = date(25, 0), day3 = date(26, 0)

        await database.addScreenTime(600, day: day1)
        await database.addScreenTime(300, day: day1)
        await database.seedScreenTime(9_999, day: day1)      // 已有实时记录：估算被忽略
        await database.seedScreenTime(1_200, day: day2)      // 没有记录：写入估算
        await database.addScreenTime(60, day: day2)          // 估算日继续累加实时部分，仍标为含估算
        await database.addScreenTime(0, day: day3)           // 0 秒不建行
        await database.addScreenTime(.nan, day: day3)

        let rows = await database.screenTime(from: day1, to: day3)
        #expect(rows == [ScreenTimeDay(day: day1, seconds: 900, estimated: false),
                         ScreenTimeDay(day: day2, seconds: 1_260, estimated: true)])

        await database.pruneScreenTime(before: day2)
        #expect(await database.screenTime(from: day1, to: day3).map(\.day) == [day2])
        await database.clear()
        #expect(await database.screenTime(from: day1, to: day3).isEmpty)
    }
}
