// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum UsageActivityMode: String, CaseIterable, Sendable {
    case daily, weekly, monthly, cumulative

    public var days: Int {
        switch self {
        case .daily: 1
        case .weekly: 7
        case .monthly: 30
        case .cumulative: 365
        }
    }
}

/// 短周期柱状图。小时以绝对时间标识，夏令时切换日自然产生 23 或 25 个桶。
public struct UsageTimeSeries: Sendable {
    public struct Bucket: Identifiable, Sendable {
        public let start: Date
        public let end: Date
        public let total: Int
        public var id: Date { start }
    }
    public let buckets: [Bucket]
    public let hasMissingHourlyData: Bool

    /// 从本地零点起按实际 60 分钟分桶；半小时夏令时地区的最后一个桶可能不足一小时。
    /// 解析与绘图必须采用同一起点，不能混用可能重叠的 Calendar hour interval。
    static func hourStart(for timestamp: Date, dayStart: Date) -> Date {
        dayStart.addingTimeInterval(floor(timestamp.timeIntervalSince(dayStart) / 3600) * 3600)
    }

    public init(rows: [ModelTokenUsage], mode: UsageActivityMode, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(mode.days - 1), to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let component: Calendar.Component = mode == .daily ? .hour : .day
        var values: [Date: Int] = [:]
        var missing = false
        for row in rows where row.day >= start && row.day <= now {
            if mode == .daily {
                guard let hours = row.hourlyTokens else { missing = missing || row.total > 0; continue }
                for (hour, tokens) in hours where hour >= start && hour <= now {
                    values[hour, default: 0] += tokens
                }
            } else {
                values[calendar.startOfDay(for: row.day), default: 0] += row.total
            }
        }
        var buckets: [Bucket] = []
        var cursor = start
        while cursor < end {
            let next = min(end, calendar.date(byAdding: component, value: 1, to: cursor)!)
            buckets.append(Bucket(start: cursor, end: next, total: values[cursor] ?? 0))
            cursor = next
        }
        self.buckets = buckets
        hasMissingHourlyData = missing
    }
}

/// 累计视图展示最近 365 个本地日期；每格是当天用量，不把累计快照再次相加。
public struct UsageActivity: Sendable {
    public struct Week: Identifiable, Sendable {
        public let start: Date
        public let days: [Date?]
        public var id: Date { start }
    }
    public let start: Date
    public let end: Date
    public let daily: [Date: Int]
    public let weeks: [Week]
    public var peak: Int { daily.values.max() ?? 0 }
    public var total: Int { daily.values.reduce(0, +) }

    public init(rows: [ModelTokenUsage], now: Date = Date(), calendar: Calendar = .current) {
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -364, to: end)!
        self.start = start; self.end = end
        var daily: [Date: Int] = [:]
        for row in rows where row.day >= start && row.day <= now {
            daily[calendar.startOfDay(for: row.day), default: 0] += row.total
        }
        self.daily = daily
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let firstWeek = calendar.date(byAdding: .day, value: -leading, to: start)!
        var weeks: [Week] = []
        for column in 0..<((leading + 365 + 6) / 7) {
            let weekStart = calendar.date(byAdding: .day, value: column * 7, to: firstWeek)!
            let dates: [Date?] = (0..<7).map { index in
                let date = calendar.date(byAdding: .day, value: index, to: weekStart)!
                return date >= start && date <= end ? date : nil
            }
            weeks.append(Week(start: max(start, weekStart), days: dates))
        }
        self.weeks = weeks
    }
}
