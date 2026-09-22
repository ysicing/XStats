// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct ModelTokenUsage: Equatable, Sendable, Identifiable, Codable {
    public let day: Date
    public let model: String
    public var input: Int = 0
    public var cached: Int = 0
    public var cacheCreated: Int = 0
    public var output: Int = 0
    public var records: Int = 0
    public var total: Int { input + output }
    public var id: String { "\(day.timeIntervalSince1970):\(model)" }

    public init(day: Date, model: String, input: Int = 0, cached: Int = 0, output: Int = 0, records: Int = 0, cacheCreated: Int = 0) {
        self.day = day; self.model = model; self.input = input
        self.cached = cached; self.output = output; self.records = records
        self.cacheCreated = cacheCreated
    }

    public mutating func add(_ other: Self) {
        input += other.input; cached += other.cached; output += other.output; records += other.records
        cacheCreated += other.cacheCreated
    }
}

public struct LocalUsageReport: Equatable, Sendable {
    public let rows: [ModelTokenUsage]
    public let fileCount: Int
    public let unreadableFiles: Int

    public init(rows: [ModelTokenUsage], fileCount: Int, unreadableFiles: Int = 0) {
        self.rows = rows; self.fileCount = fileCount; self.unreadableFiles = unreadableFiles
    }

    public func selected(days: Int, model: String? = nil, now: Date = Date(), calendar: Calendar = .current) -> [ModelTokenUsage] {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
        return rows.filter { $0.day >= start && $0.day <= now && (model == nil || $0.model == model) }
    }

    public static func total(_ rows: [ModelTokenUsage]) -> ModelTokenUsage {
        rows.reduce(into: ModelTokenUsage(day: .distantPast, model: "")) { $0.add($1) }
    }

    /// 活动图模式同时控制摘要：每日取本日，每周取本周，累计取本月；热力图仍单独取全年。
    public func summary(mode: UsageActivityMode, model: String? = nil, now: Date = Date(),
                        calendar: Calendar = .current) -> [ModelTokenUsage] {
        let component: Calendar.Component = mode == .daily ? .day : mode == .weekly ? .weekOfYear : .month
        let start = calendar.dateInterval(of: component, for: now)?.start ?? calendar.startOfDay(for: now)
        return rows.filter { $0.day >= start && $0.day <= now && (model == nil || $0.model == model) }
    }

    public static func models(_ rows: [ModelTokenUsage]) -> [ModelTokenUsage] {
        var result: [String: ModelTokenUsage] = [:]
        for row in rows {
            var value = result[row.model] ?? ModelTokenUsage(day: .distantPast, model: row.model)
            value.add(row); result[row.model] = value
        }
        return result.values.sorted { $0.total == $1.total ? $0.model < $1.model : $0.total > $1.total }
    }
}
