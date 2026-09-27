// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Dispatch
import Foundation
import Metrics
import Observation

/// 统计每天屏幕亮着且未锁定的时间。
/// 屏幕休眠、系统睡眠、锁屏和切换用户由 AppController 调用 stop()/start()；
/// 运行中的时段按需计算，退出和系统状态变化时写入。
@MainActor
@Observable
public final class ScreenTimeTracker {
    /// 今天已累计的秒数（含本次运行前写入的部分）
    public private(set) var today: TimeInterval = 0
    /// 最近 7 天，从早到晚；没有记录的日期不在其中
    public private(set) var recentDays: [ScreenTimeDay] = []
    /// 历史库中是否有任何屏幕时间记录，包含最近 7 天之外的日期。
    public private(set) var hasHistory = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let database: HistoryDatabase?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let powerLog: @Sendable () -> String?
    @ObservationIgnored private var calendar: Calendar { .current }
    @ObservationIgnored private var segmentStart: Date?
    @ObservationIgnored private var loadedDay: Date?
    @ObservationIgnored private var backfilled = false
    @ObservationIgnored private var lastPrune = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var terminating = false

    init(settings: AppSettings, database: HistoryDatabase?,
         now: @escaping () -> Date = Date.init,
         powerLog: @escaping @Sendable () -> String? = { ScreenTimeTracker.readPowerLog() }) {
        self.settings = settings
        self.database = database
        self.now = now
        self.powerLog = powerLog
    }

    var isRunning: Bool { segmentStart != nil }

    /// 读盘值加上当前未结算时段；跨午夜时只取今天的部分。
    func currentToday(at date: Date) -> TimeInterval {
        let todayKey = calendar.startOfDay(for: date)
        let recorded = loadedDay == todayKey ? today : 0
        guard let segmentStart else { return recorded }
        let live = ScreenTime.split(from: segmentStart, to: date, calendar: calendar)
            .first(where: { $0.day == todayKey })?.seconds ?? 0
        return recorded + live
    }

    /// 开始或恢复计时；重复调用无副作用。首次启动时先用电源日志补齐历史
    func start() {
        guard !terminating, settings.historyEnabled, segmentStart == nil else { return }
        let started = now()
        segmentStart = started
        if !backfilled {
            backfilled = true
            // 估算只到实时计时开始的时刻，之后由实时部分接续，二者不重叠
            let generation = self.generation
            let recordingGeneration = settings.historyRecordingGeneration
            enqueue { tracker in
                guard tracker.generation == generation,
                      tracker.settings.historyRecordingGeneration == recordingGeneration else { return }
                await tracker.backfillFromPowerLog(until: started)
            }
        }
        enqueue { await $0.reloadToday() }
    }

    /// 暂停计时并结算到此刻；重复调用无副作用
    func stop() {
        guard segmentStart != nil else { return }
        checkpoint()
        segmentStart = nil
    }

    /// 退出前完成最后一次结算；由 AppKit 延迟退出流程等待。
    func prepareForTermination() async {
        terminating = true
        stop()
        await pending?.value
    }

    /// 使清除前的在途任务失效，并把删除排在已有写入之后、新计时之前。
    func clearHistory() async {
        generation += 1
        let clearedAt = now()
        if segmentStart != nil { segmentStart = clearedAt }
        today = 0
        recentDays = []
        hasHistory = false
        enqueue { tracker in
            await tracker.database?.clear(at: clearedAt)
            await tracker.reloadToday()
            // 之前排队的 loadRecent 可能把删除前的日期写回来。
            tracker.recentDays = []
            tracker.hasHistory = false
        }
        await pending?.value
    }

    /// 借用现有的低频 Widget 刷新保存进度，不新增后台定时器。
    func checkpoint() {
        guard let start = segmentStart else { return }
        let current = now()
        segmentStart = current
        guard database != nil else { return }
        let parts = ScreenTime.split(from: start, to: current, calendar: calendar)
        let generation = self.generation
        let prune = current.timeIntervalSince(lastPrune) > 24 * 60 * 60
        if prune { lastPrune = current }
        enqueue { tracker in
            guard let database = tracker.database else { return }
            for part in parts {
                guard tracker.generation == generation else { return }
                await database.addScreenTime(part.seconds, day: part.day)
            }
            if prune { await database.pruneScreenTime(before: current.addingTimeInterval(-ScreenTime.retention)) }
            await tracker.reloadToday()
        }
    }

    /// 历史页打开时读取最近 7 天
    func loadRecent() {
        enqueue { tracker in
            guard let database = tracker.database else { return }
            let calendar = tracker.calendar
            let todayKey = calendar.startOfDay(for: tracker.now())
            guard let from = calendar.date(byAdding: .day, value: -6, to: todayKey),
                  let to = calendar.date(byAdding: .day, value: 1, to: todayKey) else { return }
            tracker.recentDays = await database.screenTime(from: from, to: to)
            tracker.hasHistory = await database.hasScreenTime()
        }
    }

    /// 数据库操作串行排队：估算补齐先于实时累加，页面读到的“今天”总与库里一致
    @ObservationIgnored private(set) var pending: Task<Void, Never>?

    private func enqueue(_ work: @escaping @MainActor (ScreenTimeTracker) async -> Void) {
        let previous = pending
        pending = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// 今天的数值始终从库里读取，包含电源日志估算与本次运行前的记录
    private func reloadToday() async {
        guard let database else { return }
        let todayKey = calendar.startOfDay(for: now())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayKey) else { return }
        let total = await database.screenTime(from: todayKey, to: tomorrow).first?.seconds ?? 0
        loadedDay = todayKey
        today = total
    }

    /// 用系统电源日志补齐 App 未运行时的日期。只填补没有记录的日期；日志首日只覆盖一部分，不计入。
    /// 今天若还没有记录，补上零点到此刻的点亮时长，之后由实时计时接续。估算值不扣除空闲与锁屏。
    private func backfillFromPowerLog(until current: Date) async {
        guard settings.historyEnabled, let database else { return }
        let generation = self.generation
        let recordingGeneration = settings.historyRecordingGeneration
        let calendar = self.calendar
        let powerLog = self.powerLog
        let totals: [Date: TimeInterval]? = await Task.detached {
            guard let log = powerLog(), let logStart = ScreenTime.logStart(powerLog: log),
                  let firstFullDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: logStart))
            else { return nil }
            let intervals = ScreenTime.displayIntervals(powerLog: log, now: current)
            return ScreenTime.totals(of: intervals, calendar: calendar).filter { $0.key >= firstFullDay }
        }.value
        guard let totals else { return }
        let oldest = calendar.startOfDay(for: current.addingTimeInterval(-ScreenTime.retention))
        for (day, seconds) in totals where day >= oldest {
            guard self.generation == generation, settings.historyEnabled,
                  settings.historyRecordingGeneration == recordingGeneration else { return }
            await database.seedScreenTime(seconds, day: day)
        }
    }

    /// 电源日志可能很长；读取和子进程运行都受限，退出不会无期限等待补录。
    nonisolated static func readPowerLog(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/pmset"),
        arguments: [String] = ["-g", "log"],
        timeout: TimeInterval = 8
    ) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.1, min(timeout, 60)) * 1_000_000_000)
        let maxBytes = 16 * 1024 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor,
                                events: Int16(POLLIN | POLLHUP), revents: 0)
        var reachedEOF = false
        while true {
            if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { break }
            let instant = DispatchTime.now().uptimeNanoseconds
            guard instant < deadline else { break }
            let remaining = deadline - instant
            let waitMs = Int32(max(1, min(remaining / 1_000_000, 1_000)))
            let ready = Darwin.poll(&descriptor, 1, waitMs)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor.fd, bytes.baseAddress, bytes.count)
            }
            if count == 0 { reachedEOF = true; break }
            guard count > 0, data.count + count <= maxBytes else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        if !reachedEOF && process.isRunning {
            process.terminate()
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        guard reachedEOF, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
