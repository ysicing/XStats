// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
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
