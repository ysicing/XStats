// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@preconcurrency import Tyme4Swift

struct CalendarLeaveOption: Identifiable, Equatable {
    var id: Int { leaveDates.count }
    let start: Date
    let end: Date
    let leaveDates: [Date]
    let totalDays: Int
}

struct CalendarHolidayPlan {
    let name: String
    let start: Date
    let end: Date
    let daysUntil: Int
    let totalDays: Int
    let leaveOptions: [CalendarLeaveOption]
}

/// 请假建议只使用已公布的工作/休息日。未知年份截断计算，不把周末当作已确认无需补班。
struct CalendarWorkday {
    let date: Date
    let isWork: Bool
    let holidayName: String?
}

extension CalendarHolidayPlan {
    static func make(days: [CalendarWorkday], today: Date, calendar: Calendar) -> Self? {
        let today = calendar.startOfDay(for: today)
        guard let seed = days.firstIndex(where: { $0.date >= today && !$0.isWork && $0.holidayName != nil }) else { return nil }
        var first = seed
        var last = seed
        while first > 0 && !days[first - 1].isWork { first -= 1 }
        while last + 1 < days.count && !days[last + 1].isWork { last += 1 }
        var options: [Int: CalendarLeaveOption] = [:]
        for before in 0...3 {
            for after in 0...(3 - before) where before + after > 0 {
                var start = first
                var end = last
                var used = 0
                while start > 0 && used + (days[start - 1].isWork ? 1 : 0) <= before {
                    start -= 1
                    if days[start].isWork { used += 1 }
                }
                used = 0
                while end + 1 < days.count && used + (days[end + 1].isWork ? 1 : 0) <= after {
                    end += 1
                    if days[end].isWork { used += 1 }
                }
                let leave = days[start...end].filter(\.isWork).map(\.date)
                guard !leave.isEmpty, leave.allSatisfy({ $0 >= today }) else { continue }
                let total = end - start + 1
                if options[leave.count].map({ $0.totalDays < total }) ?? true {
                    options[leave.count] = .init(start: days[start].date, end: days[end].date, leaveDates: leave, totalDays: total)
                }
            }
        }
        return .init(name: days[seed].holidayName ?? "", start: days[first].date, end: days[last].date,
                     daysUntil: max(0, calendar.dateComponents([.day], from: today, to: days[first].date).day ?? 0),
                     totalDays: last - first + 1, leaveOptions: options.values.sorted { $0.id < $1.id })
    }
}

extension CalendarEngine {
    /// 同一天、同一时区的结果不变；面板每次测量都会新建视图，缓存避免在主线程上反复逐日查询约 390 天
    private static var holidayPlanCache: (key: String, plan: CalendarHolidayPlan?)?

    static func holidayPlan(from date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> CalendarHolidayPlan? {
        let calendar = gregorian(timeZone: timeZone)
        let today = calendar.startOfDay(for: date)
        let key = "\(timeZone.identifier)|\(today.timeIntervalSince1970)"
        if let cached = holidayPlanCache, cached.key == key { return cached.plan }
        let plan = computeHolidayPlan(today: today, calendar: calendar)
        holidayPlanCache = (key, plan)
        return plan
    }

    private static func computeHolidayPlan(today: Date, calendar: Calendar) -> CalendarHolidayPlan? {
        var days: [CalendarWorkday] = []
        for offset in -21...370 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day, let weekday = parts.weekday else { continue }
            guard hasHolidayData(year: year) else {
                if offset >= 0 { break }
                continue
            }
            guard let solar = try? SolarDay.fromYmd(year, month, day) else { continue }
            let holiday = solar.legalHoliday
            days.append(.init(date: date, isWork: holiday?.isWork ?? (weekday != 1 && weekday != 7), holidayName: holiday?.name))
        }
        return CalendarHolidayPlan.make(days: days, today: today, calendar: calendar)
    }
}
