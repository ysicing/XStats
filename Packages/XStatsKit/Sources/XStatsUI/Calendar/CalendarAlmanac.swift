// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import WidgetData
@preconcurrency import Tyme4Swift

/// 选中日期才计算的黄历值模型，不在生成 42 格月历时重复查询宜忌表。
struct CalendarAlmanac: Identifiable {
    let id: String
    struct Hour: Identifiable {
        let id: Int
        let stem: String
        let branch: String
        let isLucky: Bool
        let timeRange: String
    }
    let ganzhiSummary: String
    let recommends: [String]
    let avoids: [String]
    let sound: String
    let opposingZodiac: String
    let ominousDirection: String
    let twelveStar: String
    let twelveStarIsLucky: Bool
    let hours: [Hour]
    let duty: String
    let luckyGods: [String]
    let unluckyGods: [String]
    let fetus: String
    let pengZu: [String]
    let star: String
    let starIsLucky: Bool
}

extension CalendarEngine {
    // 逐日类型依据国办发明电〔2025〕7号及 2024 年修订的《全国年节及纪念日放假办法》。
    // Tyme 只记录假期区间与补班，不区分法定日和调休放假；其他年份不套用此表。
    private static let statutoryHolidays2026: Set<String> = [
        "2026-01-01", "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19",
        "2026-04-05", "2026-05-01", "2026-05-02", "2026-06-19", "2026-09-25",
        "2026-10-01", "2026-10-02", "2026-10-03"
    ]
    private static let adjustedDaysOff2026: Set<String> = [
        "2026-01-02", "2026-02-20", "2026-02-23", "2026-04-06",
        "2026-05-04", "2026-05-05", "2026-10-05", "2026-10-06", "2026-10-07"
    ]

    static func widgetSummary(for day: CalendarDay) -> WidgetSnapshot.CalendarSummary {
        let schedule: WidgetSnapshot.CalendarSummary.Schedule
        if !hasHolidayData(year: day.year) {
            schedule = .unknown
        } else if let holiday = day.holiday {
            if holiday.isWork {
                schedule = .makeupWork
            } else if day.year == 2026 {
                if statutoryHolidays2026.contains(day.id) {
                    schedule = .holiday
                } else if adjustedDaysOff2026.contains(day.id) {
                    schedule = .makeupDayOff
                } else {
                    schedule = day.isWeekend ? .weekend : .unknown
                }
            } else {
                schedule = .dayOff
            }
        } else {
            schedule = day.isWeekend ? .weekend : .work
        }
        let almanac = almanac(for: day)
        return .init(dateKey: day.id, festivals: day.festivals,
                     solarTerm: day.solarTerm, schedule: schedule, holidayName: day.holiday?.name,
                     twelveStar: almanac?.twelveStar, isEcliptic: almanac?.twelveStarIsLucky ?? false,
                     recommends: Array(almanac?.recommends.prefix(3) ?? []),
                     avoids: Array(almanac?.avoids.prefix(3) ?? []))
    }

    static func almanac(for day: CalendarDay) -> CalendarAlmanac? {
        guard let solar = try? SolarDay.fromYmd(day.year, day.month, day.day) else { return nil }
        let lunar = solar.getLunarDay()
        let cycle = solar.getSixtyCycleDay()
        let gods = cycle.gods
        let star = cycle.twentyEightStar
        let pengZu = cycle.sixtyCycle.pengZu
        // Tyme 返回早子时、丑至亥、晚子时共 13 项。末项 23 点已用次日日柱，
        // 黄历的十二格取前 12 项，避免重复子时；保留农历闰月信息，直接使用原对象。
        let hours = lunar.hours.prefix(12).enumerated().map { index, hour in
            CalendarAlmanac.Hour(id: index, stem: hour.sixtyCycle.heavenStem.getName(),
                                 branch: hour.sixtyCycle.earthBranch.getName(),
                                 isLucky: hour.twelveStar.ecliptic.luck.index == 0,
                                 timeRange: index == 0 ? "00:00–00:59" : String(format: "%02d:00–%02d:59", index * 2 - 1, index * 2))
        }
        return CalendarAlmanac(
            id: day.id,
            ganzhiSummary: "\(cycle.year.getName())(\(cycle.year.earthBranch.getZodiac().getName()))年 \(cycle.month.getName())月 \(cycle.sixtyCycle.getName())日",
            recommends: cycle.recommends.map { $0.getName() }, avoids: cycle.avoids.map { $0.getName() },
            sound: cycle.sixtyCycle.sound.getName(), opposingZodiac: cycle.sixtyCycle.earthBranch.getOpposite().getZodiac().getName(),
            ominousDirection: cycle.sixtyCycle.earthBranch.getOminous().getName(),
            twelveStar: cycle.twelveStar.getName(), twelveStarIsLucky: cycle.twelveStar.ecliptic.luck.index == 0,
            hours: hours, duty: cycle.duty.getName(),
            luckyGods: gods.filter { $0.luck.index == 0 }.map { $0.getName() },
            unluckyGods: gods.filter { $0.luck.index != 0 }.map { $0.getName() },
            fetus: lunar.fetusDay.getName(),
            pengZu: [pengZu.pengZuHeavenStem.getName(), pengZu.pengZuEarthBranch.getName()],
            star: star.getName() + star.sevenStar.getName() + star.getAnimal().getName(), starIsLucky: star.luck.index == 0)
    }
}
