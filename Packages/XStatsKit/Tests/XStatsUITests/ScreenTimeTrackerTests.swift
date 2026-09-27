// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Metrics
import Testing
@testable import XStatsUI

/// 可手动推进的时钟
@MainActor
private final class FakeEnvironment {
    var now: Date
    var idle: TimeInterval = 0
    init(now: Date) { self.now = now }
}

@MainActor
@Suite struct ScreenTimeTrackerTests {
    private let calendar = Calendar.current

    private func day(_ offset: Int, hour: Int = 0, minute: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20))!
        let dayStart = calendar.date(byAdding: .day, value: offset, to: base)!
        return calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: dayStart)!
    }

    private func makeTracker(_ env: FakeEnvironment, log: String? = nil,
                             historyEnabled: Bool = true,
                             powerLog: (@Sendable () -> String?)? = nil)
        throws -> (ScreenTimeTracker, HistoryDatabase, AppSettings, () -> Void) {
        let suite = "ScreenTimeTrackerTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.historyEnabled = historyEnabled
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screen-time-\(UUID().uuidString).sqlite")
        let database = try HistoryDatabase(url: url)
        let tracker = ScreenTimeTracker(settings: settings, database: database,
                                        now: { env.now }, powerLog: powerLog ?? { log }, idleSeconds: { env.idle })
        let cleanup = {
            defaults.removePersistentDomain(forName: suite)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        return (tracker, database, settings, cleanup)
    }

    @Test func elapsedTimeIsCalculatedWithoutPeriodicWrites() async throws {
        let env = FakeEnvironment(now: day(1, hour: 10))
        let (tracker, database, _, cleanup) = try makeTracker(env)
        defer { cleanup() }
        tracker.start()
        env.now = day(1, hour: 10, minute: 30)
        #expect(tracker.currentToday(at: env.now) == 30 * 60)
        #expect(await database.screenTime(from: day(1), to: day(2)).isEmpty)
        tracker.stop()
        await settle(tracker)
        #expect(await database.screenTime(from: day(1), to: day(2)).first?.seconds == 30 * 60)
    }

    @Test func disablingHistorySettlesCurrentSegmentAndStopsTracking() async throws {
        let env = FakeEnvironment(now: day(1, hour: 10))
        let (tracker, database, settings, cleanup) = try makeTracker(env)
        defer { cleanup() }
        tracker.start()
        env.now = day(1, hour: 10, minute: 20)
        settings.historyEnabled = false
        tracker.stop()
        await settle(tracker)
        #expect(await database.screenTime(from: day(1), to: day(2)).first?.seconds == 20 * 60)
        tracker.start()
        #expect(!tracker.isRunning)
        settings.historyEnabled = true
        tracker.start()
        #expect(tracker.isRunning)
        await tracker.prepareForTermination()
    }

    private func settle(_ tracker: ScreenTimeTracker) async {
        await tracker.pending?.value
    }

    @Test(arguments: [false, true])
    func disablingDuringBackfillInvalidatesResults(reenable: Bool) async throws {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let log = """
        2026-09-20 09:00:00 +0800 Notification Display is turned on
        2026-09-20 10:00:00 +0800 Notification Display is turned off
        2026-09-21 09:00:00 +0800 Notification Display is turned on
        2026-09-21 10:00:00 +0800 Notification Display is turned off
        """
        let env = FakeEnvironment(now: day(3, hour: 12))
        let (tracker, database, settings, cleanup) = try makeTracker(env, powerLog: {
            continuation.yield(())
            release.wait()
            return log
        })
        defer { cleanup() }
        tracker.start()
        for await _ in started { break }
        settings.historyEnabled = false
        if reenable { settings.historyEnabled = true }
        release.signal()
        await settle(tracker)
        #expect(await database.screenTime(from: day(0), to: day(4)).isEmpty)
        await tracker.prepareForTermination()
    }

    @Test func clearingHistoryInvalidatesQueuedWritesAndSurvivesRelaunch() async throws {
        let env = FakeEnvironment(now: day(3, hour: 12))
        let (tracker, database, settings, cleanup) = try makeTracker(env)
        defer { cleanup() }
        tracker.start()
        await settle(tracker)
        env.now = day(3, hour: 12, minute: 1)
        tracker.checkpoint()
        await tracker.clearHistory()
        #expect(await database.screenTime(from: day(0), to: day(4)).isEmpty)
        #expect(tracker.today == 0 && tracker.recentDays.isEmpty)
        env.now = day(3, hour: 12, minute: 2)
        await tracker.prepareForTermination()
        #expect(tracker.today == 60)
        let log = """
        2026-09-20 09:00:00 +0800 Notification Display is turned on
        2026-09-20 10:00:00 +0800 Notification Display is turned off
        2026-09-21 09:00:00 +0800 Notification Display is turned on
        2026-09-21 10:00:00 +0800 Notification Display is turned off
        """
        let relaunched = ScreenTimeTracker(settings: settings, database: database,
                                           now: { env.now }, powerLog: { log }, idleSeconds: { env.idle })
        relaunched.start()
        await settle(relaunched)
        #expect(await database.screenTime(from: day(0), to: day(3)).isEmpty)
        #expect(relaunched.today == 60)
        await relaunched.prepareForTermination()
    }

    @Test func clearAfterQueuedRecentReadLeavesNoStaleBars() async throws {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let env = FakeEnvironment(now: day(3, hour: 12))
        let (tracker, database, _, cleanup) = try makeTracker(env, powerLog: {
            continuation.yield(())
            release.wait()
            return nil
        })
        defer { cleanup() }
        await database.addScreenTime(3600, day: day(2))
        tracker.start()
        tracker.loadRecent()
        for await _ in started { break }
        Task { release.signal() }
        await tracker.clearHistory()
        #expect(tracker.recentDays.isEmpty)
        #expect(!tracker.hasHistory)
        #expect(await database.screenTime(from: day(2), to: day(3)).isEmpty)
        await tracker.prepareForTermination()
    }

    @Test func screenTimeHistoryCanBeClearedWithoutMetricSamples() async throws {
        let env = FakeEnvironment(now: day(3, hour: 12))
        let (tracker, database, _, cleanup) = try makeTracker(env)
        defer { cleanup() }
        await database.seedScreenTime(3600, day: day(2))
        #expect(await database.count() == 0)
        tracker.loadRecent()
        await settle(tracker)
        #expect(tracker.hasHistory)
        await tracker.clearHistory()
        #expect(!tracker.hasHistory)
    }

    @Test func powerLogCommandHasBoundedRuntime() async {
        let result = await Task.detached {
            let start = DispatchTime.now().uptimeNanoseconds
            let log = ScreenTimeTracker.readPowerLog(executableURL: URL(fileURLWithPath: "/bin/sleep"),
                                                     arguments: ["5"], timeout: 0.15)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            return (log, elapsed)
        }.value
        #expect(result.0 == nil)
        #expect(result.1 < 3_000_000_000, "command took \(result.1) ns")
        let output = await Task.detached {
            ScreenTimeTracker.readPowerLog(executableURL: URL(fileURLWithPath: "/bin/echo"),
                                           arguments: ["display on"], timeout: 1)
        }.value
        #expect(output == "display on\n")
    }

    @Test func terminationWaitsForFinalPartialMinute() async throws {
        let env = FakeEnvironment(now: day(1, hour: 10))
        let (tracker, database, _, cleanup) = try makeTracker(env)
        defer { cleanup() }
        tracker.start()
        env.now = env.now.addingTimeInterval(35)
        await tracker.prepareForTermination()
        #expect(!tracker.isRunning)
        #expect(await database.screenTime(from: day(1), to: day(2)).first?.seconds == 35)
        tracker.start()
        #expect(!tracker.isRunning, "wake notifications must not restart tracking during termination")
    }

    @Test func countsEntireUnlockedIntervalUntilCheckpoint() async throws {
        let env = FakeEnvironment(now: day(1, hour: 10))
        let (tracker, database, _, cleanup) = try makeTracker(env)
        defer { cleanup() }
        tracker.start()
        env.now = day(1, hour: 10, minute: 10)
        tracker.checkpoint()
        env.now = day(1, hour: 10, minute: 30)
        tracker.checkpoint()
        tracker.stop()
        await settle(tracker)
        #expect(tracker.today == TimeInterval(30 * 60), "checkpoint records the entire unlocked interval")
        let rows = await database.screenTime(from: day(1), to: day(2))
        #expect(rows.first?.seconds == TimeInterval(30 * 60), "rows: \(rows)")
        #expect(rows.first?.estimated == false)
    }

    @Test func pausedTimeAndDisabledHistoryAreNotCounted() async throws {
        let env = FakeEnvironment(now: day(1, hour: 9))
        let (tracker, database, settings, cleanup) = try makeTracker(env)
        defer { cleanup() }
        tracker.start()
        tracker.start()                                   // 重复 start 不重置起点
        env.now = day(1, hour: 9, minute: 5)
        tracker.stop()
        tracker.stop()                                    // 重复 stop 不重复结算
        env.now = day(1, hour: 12)                        // 暂停期间（锁屏、睡眠）
        settings.historyEnabled = false
        tracker.stop()
        env.now = day(1, hour: 12, minute: 30)
        tracker.start()                                   // 关闭期间不会启动
        settings.historyEnabled = true
        tracker.start()
        env.now = day(1, hour: 12, minute: 32)
        tracker.stop()
        await settle(tracker)
        #expect(!tracker.isRunning)
        let rows = await database.screenTime(from: day(1), to: day(2))
        #expect(rows.first?.seconds == TimeInterval(7 * 60), "rows: \(rows)")
    }

    @Test func sessionAcrossMidnightIsSplitBetweenDays() async throws {
        let env = FakeEnvironment(now: day(1, hour: 23, minute: 50))
        let (tracker, database, _, cleanup) = try makeTracker(env)
        defer { cleanup() }
        tracker.start()
        env.now = day(2, hour: 0, minute: 20)
        #expect(tracker.currentToday(at: env.now) == 20 * 60)
        #expect(await database.screenTime(from: day(1), to: day(3)).isEmpty)
        tracker.stop()
        await settle(tracker)
        let rows = await database.screenTime(from: day(1), to: day(3))
        #expect(rows.map(\.seconds) == [TimeInterval(10 * 60), TimeInterval(20 * 60)], "rows: \(rows)")
    }

    @Test func powerLogBackfillsOnlyFullyCoveredDaysWithoutRecords() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        func line(_ date: Date, _ on: Bool) -> String {
            "\(formatter.string(from: date)) Notification        \tDisplay is turned \(on ? "on" : "off")"
        }
        let log = [
            line(day(0, hour: 20), true), line(day(0, hour: 22), false),   // 日志首日：只覆盖一部分，不补
            line(day(1, hour: 9), true), line(day(1, hour: 12), false),    // 已有实时记录：不覆盖
            line(day(2, hour: 9), true), line(day(2, hour: 11), false),    // 补 2 小时估算
            line(day(3, hour: 8), true),                                   // 今天：补到启动时刻
        ].joined(separator: "\n")
        let env = FakeEnvironment(now: day(3, hour: 9))
        let (tracker, database, _, cleanup) = try makeTracker(env, log: log)
        defer { cleanup() }
        await database.addScreenTime(1_800, day: day(1))

        tracker.start()
        env.now = day(3, hour: 9, minute: 10)
        tracker.stop()
        await settle(tracker)

        let rows = await database.screenTime(from: day(0), to: day(4))
        #expect(rows == [
            ScreenTimeDay(day: day(1), seconds: 1_800, estimated: false),
            ScreenTimeDay(day: day(2), seconds: 2 * 3600, estimated: true),
            // 零点前没有数据；08:00 点亮到 09:00 启动为估算，其后 10 分钟为实时
            ScreenTimeDay(day: day(3), seconds: 3600 + 600, estimated: true),
        ], "rows: \(rows)")
    }

    @Test func missingOrUnreadablePowerLogIsIgnored() async throws {
        let env = FakeEnvironment(now: day(1, hour: 9))
        let (tracker, database, _, cleanup) = try makeTracker(env, log: "pmset: not permitted")
        defer { cleanup() }
        tracker.start()
        env.now = day(1, hour: 9, minute: 1)
        tracker.stop()
        await settle(tracker)
        #expect(await database.screenTime(from: day(0), to: day(2)).map(\.seconds) == [TimeInterval(60)])
    }


    @Test func timeAfterUserLeavesIsNotCountedEvenIfDisplayStaysOn() async throws {
        // 防休眠让屏幕常亮：10:00 起无人操作，11:00 的定期结算只计到最后输入后的 5 分钟
        let env = FakeEnvironment(now: day(1, hour: 9))
        let (tracker, database, _, cleanup) = try makeTracker(env)
        defer { cleanup() }
        tracker.start()
        env.now = day(1, hour: 11)
        env.idle = 60 * 60
        tracker.checkpoint()
        env.now = day(1, hour: 11, minute: 30)          // 11:00 回来一直在用
        env.idle = 0
        tracker.stop()
        await tracker.pending?.value
        let rows = await database.screenTime(from: day(1), to: day(2))
        #expect(rows.first?.seconds == TimeInterval((65 + 30) * 60), "rows: \(rows)")
    }

    @Test func liveScreenTimeStopsGrowingAfterIdleThreshold() async throws {
        let env = FakeEnvironment(now: day(1, hour: 10))
        let (tracker, database, _, cleanup) = try makeTracker(env)
        defer { cleanup() }
        tracker.start()

        env.now = day(1, hour: 10, minute: 30)
        env.idle = 30 * 60
        #expect(tracker.currentToday(at: env.now) == 5 * 60)
        env.now = day(1, hour: 10, minute: 40)
        env.idle = 40 * 60
        #expect(tracker.currentToday(at: env.now) == 5 * 60)

        tracker.stop()
        await tracker.pending?.value
        #expect(await database.screenTime(from: day(1), to: day(2)).first?.seconds == 5 * 60)
    }

    @Test func reenablingHistoryDoesNotBackfillTheDisabledDays() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        func line(_ date: Date, _ on: Bool) -> String {
            "\(formatter.string(from: date)) Notification        \tDisplay is turned \(on ? "on" : "off")"
        }
        let log = [line(day(0, hour: 8), false),
                   line(day(1, hour: 9), true), line(day(1, hour: 11), false),     // 关闭历史期间
                   line(day(2, hour: 9), true), line(day(2, hour: 10), false)].joined(separator: "\n")
        let env = FakeEnvironment(now: day(3, hour: 9))
        let (tracker, database, settings, cleanup) = try makeTracker(env, log: log, historyEnabled: false)
        defer { cleanup() }
        tracker.start()                                   // 关闭时不计时、不补录
        settings.historyEnabled = true
        tracker.historySettingChanged()
        tracker.start()
        env.now = day(3, hour: 9, minute: 10)
        tracker.stop()
        await tracker.pending?.value
        let rows = await database.screenTime(from: day(0), to: day(4))
        #expect(rows.map(\.day) == [day(3)], "disabled days were backfilled: \(rows)")
        #expect(rows.first?.estimated == false)

        // 跨重启同样生效：新进程首次启动补录时也跳过这些日期
        let relaunched = ScreenTimeTracker(settings: settings, database: database,
                                           now: { env.now }, powerLog: { log }, idleSeconds: { 0 })
        relaunched.start()
        relaunched.stop()
        await relaunched.pending?.value
        #expect(await database.screenTime(from: day(0), to: day(3)).isEmpty)
    }

    @Test func terminationCancelsASlowPowerLogRead() async throws {
        let (startedRead, continuation) = AsyncStream<Void>.makeStream()
        let env = FakeEnvironment(now: day(1, hour: 9))
        let (tracker, _, _, cleanup) = try makeTracker(env, powerLog: {
            // 模拟读取很慢的 pmset：直到被取消才返回
            continuation.yield(())
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { return nil }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        })
        defer { cleanup() }
        tracker.start()
        for await _ in startedRead { break }
        let started = Date()
        await tracker.prepareForTermination()
        #expect(Date().timeIntervalSince(started) < 2, "termination waited for the power log read")
    }
}
