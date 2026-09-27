// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 某一天的屏幕使用时间；`estimated` 表示含有电源日志估算、可能包含锁屏时间的部分
public struct ScreenTimeDay: Sendable, Equatable {
    /// 当地零点
    public var day: Date
    public var seconds: TimeInterval
    public var estimated: Bool

    public init(day: Date, seconds: TimeInterval, estimated: Bool) {
        self.day = day
        self.seconds = seconds
        self.estimated = estimated
    }
}

/// 屏幕使用时间的纯计算：按天拆分、解析系统电源日志
public enum ScreenTime {
    public static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// 把一段时间按当地自然日拆开，跨过零点的部分分别计入两天
    public static func split(from start: Date, to end: Date, calendar: Calendar = .current) -> [(day: Date, seconds: TimeInterval)] {
        guard end > start else { return [] }
        var parts: [(Date, TimeInterval)] = []
        var cursor = start
        while cursor < end {
            let day = calendar.startOfDay(for: cursor)
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? end
            let segmentEnd = min(next, end)
            parts.append((day, segmentEnd.timeIntervalSince(cursor)))
            cursor = segmentEnd
        }
        return parts
    }

    /// 从 `pmset -g log` 输出中取出屏幕点亮的时段。日志格式没有公开文档，只识别
    /// “Display is turned on/off” 两类行；日志末尾仍亮着的时段截止到 `now`
    public static func displayIntervals(powerLog: String, now: Date) -> [DateInterval] {
        let formatter = logDateFormatter()
        var events: [(date: Date, on: Bool)] = []
        for line in powerLog.split(separator: "\n") where line.contains("Display is turned ") {
            let on = line.contains("Display is turned on")
            guard on || line.contains("Display is turned off"),
                  let date = timestamp(of: line, formatter: formatter) else { continue }
            events.append((date, on))
        }
        events.sort { $0.date < $1.date }
        var intervals: [DateInterval] = []
        var litSince: Date?
        for event in events {
            if event.on {
                if litSince == nil { litSince = event.date }
            } else if let start = litSince {
                intervals.append(DateInterval(start: start, end: event.date))
                litSince = nil
            }
        }
        if let start = litSince, now > start { intervals.append(DateInterval(start: start, end: now)) }
        return intervals
    }

    /// 电源日志里最早一条记录的时间；它所在的那天之前没有数据，当天也只覆盖了一部分
    public static func logStart(powerLog: String) -> Date? {
        let formatter = logDateFormatter()
        for line in powerLog.split(separator: "\n") {
            if let date = timestamp(of: line, formatter: formatter) { return date }
        }
        return nil
    }

    /// 各时段按当地自然日累加
    public static func totals(of intervals: [DateInterval], calendar: Calendar = .current) -> [Date: TimeInterval] {
        var totals: [Date: TimeInterval] = [:]
        for interval in intervals {
            for part in split(from: interval.start, to: interval.end, calendar: calendar) {
                totals[part.day, default: 0] += part.seconds
            }
        }
        return totals
    }

    private static func logDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }

    /// 行首固定为 “2026-09-26 13:04:11 +0800” 这样 25 个字符
    private static func timestamp(of line: Substring, formatter: DateFormatter) -> Date? {
        line.count > 25 ? formatter.date(from: String(line.prefix(25))) : nil
    }
}
