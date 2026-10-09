// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 护眼提醒偏好；旧设置中的其他键会被忽略，不触发已移除的功能。
public struct WellnessPreferences: Codable, Equatable, Sendable {
    public var breakEnabled = false
    public var breakIntervalMinutes = 30
    public var breakSeconds = 60

    public init() {}
    static let breakIntervals = [15, 20, 30, 45, 60, 90]
    static let breakDurations = [20, 30, 60, 120, 180]

    private enum CodingKeys: String, CodingKey { case breakEnabled, breakIntervalMinutes, breakSeconds }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        breakEnabled = try values.decodeIfPresent(Bool.self, forKey: .breakEnabled) ?? false
        breakIntervalMinutes = try values.decodeIfPresent(Int.self, forKey: .breakIntervalMinutes) ?? 30
        breakSeconds = try values.decodeIfPresent(Int.self, forKey: .breakSeconds) ?? 60
    }

    var normalized: Self {
        var value = self
        if !Self.breakIntervals.contains(value.breakIntervalMinutes) { value.breakIntervalMinutes = 30 }
        if !Self.breakDurations.contains(value.breakSeconds) { value.breakSeconds = 60 }
        return value
    }
}

enum HealthReminderKind: String, CaseIterable, Identifiable, Sendable {
    case rest
    var id: Self { self }
}

/// 只有一个最近截止点；待处理提醒不重复排队，合并窗口限制为五分钟。
struct HealthReminderSchedule {
    static let mergeWindow: TimeInterval = 300
    private(set) var pending: Set<HealthReminderKind> = []
    private var deadlines: [HealthReminderKind: TimeInterval] = [:]
    private var suspendedRemaining: [HealthReminderKind: TimeInterval]?
    private var intervals: [HealthReminderKind: TimeInterval] = [:]

    mutating func configure(preferences: WellnessPreferences, enabled: Bool, at now: TimeInterval) {
        let preferences = preferences.normalized
        let updated: [HealthReminderKind: TimeInterval] = enabled ? Dictionary(uniqueKeysWithValues:
            [(HealthReminderKind.rest, preferences.breakEnabled, preferences.breakIntervalMinutes)]
                .filter { $0.1 }.map { ($0.0, Double($0.2) * 60) }) : [:]
        for kind in HealthReminderKind.allCases where intervals[kind] != updated[kind] {
            pending.remove(kind)
            deadlines[kind] = updated[kind].map { now + $0 }
            if suspendedRemaining != nil {
                suspendedRemaining?[kind] = updated[kind]
                deadlines[kind] = nil
            }
        }
        intervals = updated
    }

    func nextWake(focusBreakAt: TimeInterval? = nil) -> TimeInterval? {
        deadlines.values.map { coordinatedDeadline($0, focusBreakAt: focusBreakAt) }.min()
    }

    func deadline(for kind: HealthReminderKind, focusBreakAt: TimeInterval? = nil) -> TimeInterval? {
        deadlines[kind].map { coordinatedDeadline($0, focusBreakAt: focusBreakAt) }
    }

    mutating func due(at now: TimeInterval, focusBreakAt: TimeInterval? = nil) -> Set<HealthReminderKind> {
        let due = Set(deadlines.compactMap { kind, deadline in
            coordinatedDeadline(deadline, focusBreakAt: focusBreakAt) <= now ? kind : nil
        })
        for kind in due { deadlines[kind] = nil }
        pending.formUnion(due)
        return due
    }

    mutating func mergeForBreak(at now: TimeInterval) -> Set<HealthReminderKind> {
        let upcoming = Set(deadlines.compactMap { kind, deadline in
            deadline <= now + Self.mergeWindow ? kind : nil
        })
        for kind in upcoming { deadlines[kind] = nil }
        pending.formUnion(upcoming)
        return pending
    }

    mutating func acknowledge(_ kind: HealthReminderKind, at now: TimeInterval) {
        pending.remove(kind)
        deadlines[kind] = intervals[kind].map { now + $0 }
    }

    mutating func postpone(_ kind: HealthReminderKind, at now: TimeInterval) {
        pending.remove(kind)
        if intervals[kind] != nil { deadlines[kind] = now + 600 }
    }

    mutating func suspend(at now: TimeInterval) {
        guard suspendedRemaining == nil else { return }
        suspendedRemaining = deadlines.mapValues { max(0, $0 - now) }
        // 未确认的旧提示不在解锁时连发，重新给予一次完整间隔。
        for kind in pending { suspendedRemaining?[kind] = intervals[kind] }
        deadlines.removeAll()
        pending.removeAll()
    }

    mutating func resume(at now: TimeInterval) {
        guard let remaining = suspendedRemaining else { return }
        deadlines = remaining.mapValues { now + $0 }
        suspendedRemaining = nil
    }

    private func coordinatedDeadline(_ due: TimeInterval, focusBreakAt: TimeInterval?) -> TimeInterval {
        guard let focusBreakAt, focusBreakAt >= due, focusBreakAt - due <= Self.mergeWindow else { return due }
        return focusBreakAt
    }
}

enum WellnessActivityKind: String, Codable, Sendable { case focus, rest }

struct WellnessActivity: Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    let kind: WellnessActivityKind
    let startedAt: Date
    let endedAt: Date
    var completed: Bool
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

struct WellnessDaySummary: Equatable, Sendable, Identifiable {
    let date: Date
    var focusSeconds: TimeInterval = 0
    var restSeconds: TimeInterval = 0
    var focusCount = 0
    var id: Date { date }
}

struct WellnessSummary: Equatable, Sendable {
    let days: [WellnessDaySummary]
    let todayActivities: [WellnessActivity]
    var today: WellnessDaySummary? { days.last }

    static func make(activities: [WellnessActivity], at now: Date, calendar: Calendar = .current) -> Self {
        let today = calendar.startOfDay(for: now)
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: today) }
        var days = dates.map { WellnessDaySummary(date: $0) }
        for activity in activities {
            for index in days.indices {
                guard let end = calendar.date(byAdding: .day, value: 1, to: days[index].date) else { continue }
                let seconds = max(0, min(activity.endedAt, end).timeIntervalSince(max(activity.startedAt, days[index].date)))
                switch activity.kind {
                case .focus:
                    days[index].focusSeconds += seconds
                    if activity.completed && activity.endedAt >= days[index].date && activity.endedAt < end {
                        days[index].focusCount += 1
                    }
                case .rest: days[index].restSeconds += seconds

                }
            }
        }
        return Self(days: days, todayActivities: activities.filter { $0.endedAt >= today && $0.startedAt <= now })
    }
}

/// 按阶段变化记一条，秒级刷新不落盘；完成截止点以旧阶段 deadline 为准。
struct RestActivityTracker {
    private struct Segment {
        let phase: RestPhase
        let started: UInt64
        let date: Date
        let deadline: UInt64
    }
    private var segment: Segment?

    mutating func update(phase: RestPhase, running: Bool, deadline: UInt64, now: UInt64, date: Date) -> WellnessActivity? {
        if let current = segment, running && current.phase == phase && current.deadline == deadline { return nil }
        let completed = finish(at: now)
        if running { segment = Segment(phase: phase, started: now, date: date, deadline: deadline) }
        return completed
    }

    mutating func finish(at now: UInt64) -> WellnessActivity? {
        guard let current = segment else { return nil }
        segment = nil
        let end = min(now, current.deadline)
        guard end > current.started else { return nil }
        let elapsed = Double(end - current.started) / 1_000_000_000
        return WellnessActivity(kind: current.phase == .work ? .focus : .rest,
                                startedAt: current.date, endedAt: current.date.addingTimeInterval(elapsed),
                                completed: now >= current.deadline)
    }
}
