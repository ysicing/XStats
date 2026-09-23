// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
// Tyme 1.5 使用 Swift 5；并发兼容仅限此适配层，所有访问由 MainActor 串行化。
@preconcurrency import Tyme4Swift

/// 公历是月历的坐标；其余信息可独立隐藏，设置以稳定 rawValue 保存和同步。
public enum CalendarFeature: String, CaseIterable, Identifiable, Sendable {
    case lunar, weekdays, holidays, festivals, solarTerms, ganzhi, dogDays, plumRain, tibetan, hijri
    public var id: String { rawValue }
    public static let defaults: Set<Self> = [.lunar, .weekdays, .holidays, .festivals, .solarTerms]

    var title: String {
        switch self {
        case .lunar: tr("农历")
        case .weekdays: tr("星期")
        case .holidays: tr("法定节假日与调休")
        case .festivals: tr("传统与公历节日")
        case .solarTerms: tr("二十四节气")
        case .ganzhi: tr("干支")
        case .dogDays: tr("三伏天")
        case .plumRain: tr("梅雨天")
        case .tibetan: tr("藏历")
        case .hijri: tr("回历")
        }
    }
}

struct CalendarMonth: Equatable, Hashable {
    static let years = 1900...2100
    var year: Int
    var month: Int

    func shifted(by delta: Int) -> Self? {
        let index = year * 12 + month - 1 + delta
        let result = Self(year: index / 12, month: index % 12 + 1)
        return Self.years.contains(result.year) ? result : nil
    }
}

struct CalendarDay: Identifiable, Equatable {
    struct Holiday: Equatable {
        let name: String
        let isWork: Bool
    }
    let date: Date
    let year: Int
    let month: Int
    let day: Int
    /// Foundation 的星期编号：1 为周日。
    let weekday: Int
    let lunarLabel: String
    let lunarSummary: String
    let ganzhiDay: String
    let ganzhiSummary: String
    let festivals: [String]
    let solarTerm: String?
    let holiday: Holiday?
    let dogDays: String?
    let plumRain: String?
    var id: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var isWeekend: Bool { weekday == 1 || weekday == 7 }

    /// 每格仅显示一条主注释，所有启用的信息在选中日期详情中保留。
    func subtitle(features: Set<CalendarFeature>) -> String {
        if features.contains(.festivals), let festival = festivals.first { return festival }
        if features.contains(.solarTerms), let solarTerm { return solarTerm }
        if features.contains(.dogDays), let dogDays { return dogDays }
        if features.contains(.plumRain), let plumRain { return plumRain }
        return features.contains(.lunar) ? lunarLabel : ""
    }
}

struct CalendarDetail: Identifiable {
    let feature: CalendarFeature
    let value: String
    var isUnavailable = false
    var id: CalendarFeature { feature }
}

/// Tyme 使用可变的静态表；统一在主线程读取，不把其引用类型暴露给界面或跨线程共享。
@MainActor
enum CalendarEngine {
    static func gregorian(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func today(at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> CalendarDay? {
        let parts = gregorian(timeZone: timeZone).dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return self.day(year: year, month: month, day: day, timeZone: timeZone)
    }

    /// 保留同月的公历选择，并用当前时区重建 Date；不能复用旧时区的绝对时间。
    static func selection(_ previous: CalendarDay?, in month: CalendarMonth,
                          timeZone: TimeZone = .autoupdatingCurrent) -> CalendarDay? {
        let day = previous?.year == month.year && previous?.month == month.month ? (previous?.day ?? 1) : 1
        return self.day(year: month.year, month: month.month, day: day, timeZone: timeZone)
    }

    static func month(year: Int, month: Int, firstWeekday: Int,
                      timeZone: TimeZone = .autoupdatingCurrent) -> [CalendarDay] {
        guard CalendarMonth.years.contains(year), (1...12).contains(month),
              let first = day(year: year, month: month, day: 1, timeZone: timeZone) else { return [] }
        let calendar = gregorian(timeZone: timeZone)
        let weekStart = firstWeekday == 1 ? 1 : 2
        let offset = (first.weekday - weekStart + 7) % 7
        // 用日历加天而非 86400 秒；夏令时切换不能导致重复日期或漏掉日期。
        return (0..<42).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index - offset, to: first.date) else { return nil }
            return today(at: date, timeZone: timeZone)
        }
    }

    static func day(year: Int, month: Int, day: Int,
                    timeZone: TimeZone = .autoupdatingCurrent) -> CalendarDay? {
        // 包含边缘月份的相邻日期；界面浏览限制在 1900–2100 年，避开历史历法切换歧义。
        guard (1899...2101).contains(year), (1...12).contains(month),
              let solar = try? SolarDay.fromYmd(year, month, day) else { return nil }
        let calendar = gregorian(timeZone: timeZone)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { return nil }
        let lunar = solar.getLunarDay()
        let cycle = solar.getSixtyCycleDay()
        let term = solar.termDay
        let festivals = [lunar.festival?.getName(), solar.festival?.getName()].compactMap { $0 }
        return CalendarDay(date: date, year: year, month: month, day: day,
                           weekday: calendar.component(.weekday, from: date),
                           lunarLabel: lunar.day == 1 ? lunar.lunarMonth.getName() : lunar.getName(),
                           lunarSummary: lunar.description, ganzhiDay: cycle.sixtyCycle.getName(),
                           ganzhiSummary: "\(cycle.year.getName())年 \(cycle.month.getName())月 \(cycle.sixtyCycle.getName())日",
                           festivals: festivals, solarTerm: term.dayIndex == 0 ? term.solarTerm.getName() : nil,
                           holiday: solar.legalHoliday.map { .init(name: $0.name, isWork: $0.isWork) },
                           dogDays: solar.dogDay?.description, plumRain: solar.plumRainDay?.description)
    }

    /// 年份覆盖来自固定版本的数据本身；未收录年份不能把 nil 解读为“无需调休”。
    static func hasHolidayData(year: Int) -> Bool { holidayYears.contains(year) }
    private static let holidayYears: Set<Int> = {
        let data = Array(LegalHoliday.DATA.utf8)
        return Set(stride(from: 0, to: data.count, by: 13).compactMap { index in
            guard index + 4 <= data.count else { return nil }
            return Int(String(decoding: data[index..<(index + 4)], as: UTF8.self))
        })
    }()

    static func additionalCalendars(for day: CalendarDay, features: Set<CalendarFeature>) -> [CalendarDetail] {
        guard let solar = try? SolarDay.fromYmd(day.year, day.month, day.day) else { return [] }
        var details: [CalendarDetail] = []
        if features.contains(.tibetan) {
            // 上游从固定起点向前扫描，范围外部分路径使用 try!；先检查完整的公历覆盖范围。
            let supported = day.id >= "1951-01-08" && day.id <= "2051-02-11"
            let value = supported ? (try? solar.getRabByungDay().description) : nil
            details.append(.init(feature: .tibetan, value: value ?? tr("该日期暂无藏历数据"), isUnavailable: value == nil))
        }
        if features.contains(.hijri) {
            details.append(.init(feature: .hijri, value: solar.getHijriDay().description))
        }
        return details
    }
}
