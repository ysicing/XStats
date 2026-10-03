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
    /// 同一天的小时 Token 分布；nil 表示旧数据没有小时明细，不能当作午夜用量。
    public var hourlyTokens: [Date: Int]?
    public var records: Int = 0
    public var total: Int { input + output }
    public var id: String { "\(day.timeIntervalSince1970):\(model)" }

    public init(day: Date, model: String, input: Int = 0, cached: Int = 0, output: Int = 0, records: Int = 0, cacheCreated: Int = 0, hourlyTokens: [Date: Int]? = nil) {
        self.day = day; self.model = model; self.input = input
        self.cached = cached; self.output = output; self.records = records
        self.cacheCreated = cacheCreated
        self.hourlyTokens = hourlyTokens
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

    /// 摘要、费用、排行和图表共用滚动窗口，包含今天；累计仅指保留的最近 365 天。
    public func summary(mode: UsageActivityMode, model: String? = nil, now: Date = Date(),
                        calendar: Calendar = .current) -> [ModelTokenUsage] {
        selected(days: mode.days, model: model, now: now, calendar: calendar)
    }

    /// 同一天同一模型会来自多个会话文件，而 `ModelTokenUsage.id` 正以“日期 + 模型”为键，
    /// 所以必须先合并再交给视图，否则 `rows` 里会出现大量重复 id。
    public static func aggregated(_ rows: some Sequence<ModelTokenUsage>) -> [ModelTokenUsage] {
        var merged: [String: ModelTokenUsage] = [:]
        for row in rows {
            var value = merged[row.id] ?? ModelTokenUsage(day: row.day, model: row.model)
            value.add(row)
            // 小时明细只在同一天/同模型间合并；任一旧行缺失明细时，不伪造完整分布。
            if let previous = merged[row.id] {
                if let priorHours = previous.hourlyTokens, let hours = row.hourlyTokens {
                    value.hourlyTokens = priorHours.merging(hours, uniquingKeysWith: +)
                } else {
                    value.hourlyTokens = nil
                }
            } else {
                value.hourlyTokens = row.hourlyTokens
            }
            merged[row.id] = value
        }
        // 必须定序：解析状态存在字典里，冷扫描和从检查点恢复的迭代顺序不同，
        // 顺序不定会让每次刷新都产生一个“不相等”的报告，白白触发重绘并清掉悬停提示。
        return merged.values.sorted { $0.day == $1.day ? $0.model < $1.model : $0.day < $1.day }
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
