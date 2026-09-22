// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum UsageActivityMode: String, CaseIterable, Sendable {
    case daily, weekly, cumulative
}

/// 三种图形共用同一年度窗口和筛选结果，累计值从窗口起点累加到所选周。
public struct UsageActivity: Sendable {
    public struct Week: Identifiable, Sendable {
        public let start: Date
        public let end: Date
        public let days: [Date?]
        public let total: Int
        public let cumulative: Int
        public var id: Date { start }
    }
    public let start: Date
    public let end: Date
    public let daily: [Date: Int]
    public let weeks: [Week]

    public init(rows: [ModelTokenUsage], now: Date = Date(), calendar: Calendar = .current) {
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -364, to: end)!
        self.start = start; self.end = end
        var daily: [Date: Int] = [:]
        for row in rows where row.day >= start && row.day <= end {
            daily[calendar.startOfDay(for: row.day), default: 0] += row.total
        }
        self.daily = daily
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let firstWeek = calendar.date(byAdding: .day, value: -leading, to: start)!
        var weeks: [Week] = []
        var cumulative = 0
        for column in 0..<((leading + 365 + 6) / 7) {
            let weekStart = calendar.date(byAdding: .day, value: column * 7, to: firstWeek)!
            let dates: [Date?] = (0..<7).map { index in
                let date = calendar.date(byAdding: .day, value: index, to: weekStart)!
                return date >= start && date <= end ? date : nil
            }
            let total = dates.compactMap { $0 }.reduce(0) { $0 + (daily[$1] ?? 0) }
            cumulative += total
            weeks.append(Week(start: max(start, weekStart), end: dates.compactMap { $0 }.last ?? end,
                              days: dates, total: total, cumulative: cumulative))
        }
        self.weeks = weeks
    }

    public func peak(for mode: UsageActivityMode) -> Int {
        switch mode {
        case .daily: daily.values.max() ?? 0
        case .weekly: weeks.map(\.total).max() ?? 0
        case .cumulative: weeks.last?.cumulative ?? 0
        }
    }

    public static func filledCells(value: Int, peak: Int) -> Int {
        guard value > 0, peak > 0 else { return 0 }
        return min(7, max(1, Int(ceil(Double(value) / Double(peak) * 7))))
    }

    /// 周用量可能被单周峰值拉开数量级，用平方根提升低用量周的辨识度；累计保持线性递进。
    public static func colorIntensity(value: Int, peak: Int, mode: UsageActivityMode) -> Double {
        guard value > 0, peak > 0 else { return 0 }
        let fraction = min(1, Double(value) / Double(peak))
        let strength = mode == .weekly ? sqrt(fraction) : fraction
        return 0.25 + 0.75 * strength
    }
}
