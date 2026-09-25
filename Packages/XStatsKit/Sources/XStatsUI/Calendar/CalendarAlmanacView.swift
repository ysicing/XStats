// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import SwiftUI

/// 传统黄历详情：以分格表呈现同一日期的数据，正文保留 Tyme 的传统名称。
struct CalendarAlmanacView: View {
    let day: CalendarDay
    let almanac: CalendarAlmanac
    let features: Set<CalendarFeature>
    private let heading = Color.dynamic(light: 0xAE743F, dark: 0xDBAC79)
    private let lucky = Color.dynamic(light: 0x288B3B, dark: 0x63CC76)

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text(dateTitle).font(.system(size: 13)).foregroundStyle(.secondary)
                if features.contains(.lunar) {
                    Text(day.lunarSummary).font(.system(size: 21)).foregroundStyle(.red)
                }
                Text(almanac.ganzhiSummary).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                advice(tr("宜"), entries: almanac.recommends, color: lucky)
                advice(tr("忌"), entries: almanac.avoids, color: .red)
            }
            almanacTable
            supplementaryDetails
        }
        .padding(.bottom, 6)
        .textSelection(.enabled)
    }

    private var dateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = CalendarEngine.gregorian()
        formatter.setLocalizedDateFormatFromTemplate(features.contains(.weekdays) ? "yMMMMdEEEE" : "yMMMMd")
        return formatter.string(from: day.date)
    }

    private func advice(_ label: String, entries: [String], color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .padding(4).background(color, in: Capsule())
            Text(entries.isEmpty ? tr("无") : entries.joined(separator: "  "))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
    }

    private var almanacTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tile(tr("纳音")) { Text(almanac.sound) }
                verticalLine
                tile(tr("冲煞")) { Text(tr("冲\(almanac.opposingZodiac) 煞\(almanac.ominousDirection)")) }
                verticalLine
                tile(tr("值神")) {
                    HStack(spacing: 4) {
                        Text(almanac.twelveStar)
                        luckLabel(almanac.twelveStarIsLucky)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            hourTable
            Divider()
            HStack(spacing: 0) {
                sideTile(tr("建除十二神"), value: almanac.duty)
                verticalLine
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        tile(tr("吉神宜趋")) { Text(almanac.luckyGods.joined(separator: "  ")) }
                        verticalLine
                        tile(tr("今日胎神")) { Text(almanac.fetus) }
                        verticalLine
                        tile(tr("凶神宜忌")) { Text(almanac.unluckyGods.joined(separator: "  ")) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    tile(tr("彭祖百忌")) { Text(almanac.pengZu.joined(separator: "\n")) }
                }
                verticalLine
                sideTile(tr("二十八星宿"), value: almanac.star, isLucky: almanac.starIsLucky)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .overlay { Rectangle().strokeBorder(DS.Palette.border, lineWidth: 1) }
    }

    private func sideTile(_ title: String, value: String, isLucky: Bool? = nil) -> some View {
        // 拆出无障碍文案：写在视图链里时 Swift 6.2 无法在限时内完成类型推断。
        let luck: String = isLucky.map { " " + tr($0 ? "吉" : "凶") } ?? ""
        let accessibilityText: String = title + " " + value + luck
        return Group {
            if L10n.language.isChinese {
                HStack(spacing: 6) {
                    Text(title.map(String.init).joined(separator: "\n"))
                        .font(.system(size: 16)).foregroundStyle(heading)
                    VStack(spacing: 5) {
                        Text(value.map(String.init).joined(separator: "\n")).foregroundStyle(.secondary)
                        if let isLucky { luckLabel(isLucky) }
                    }
                    .font(.system(size: 12))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
            } else {
                VStack(spacing: 8) {
                    Text(title).font(.system(size: 13)).foregroundStyle(heading)
                    Text(value).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let isLucky { luckLabel(isLucky) }
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: L10n.language.isChinese ? 52 : 72)
        .padding(.horizontal, 5)
        .padding(.vertical, 10)
    }

    private var hourTable: some View {
        HStack(spacing: 0) {
            Text(tr("时辰吉凶"))
                .font(.system(size: 15)).foregroundStyle(heading)
                .multilineTextAlignment(.center)
                .frame(width: L10n.language.isChinese ? 42 : 60).padding(.horizontal, 6)
                .help(tr("子时显示当日早子时；23 点起的晚子时按次日干支计算"))
            verticalLine
            ForEach(almanac.hours) { hour in
                VStack(spacing: 2) {
                    Text(hour.stem)
                    Text(hour.branch)
                    luckLabel(hour.isLucky, compact: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .help(hour.timeRange)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(hour.stem)\(hour.branch) \(hour.timeRange) \(tr(hour.isLucky ? "吉" : "凶"))")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var verticalLine: some View {
        Rectangle().fill(DS.Palette.border).frame(width: 1)
    }

    private func tile<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 16)).foregroundStyle(heading)
            content().font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func luckLabel(_ isLucky: Bool, compact: Bool = false) -> some View {
        if compact && !L10n.language.isChinese {
            Image(systemName: isLucky ? "checkmark" : "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isLucky ? lucky : .red)
                .accessibilityLabel(tr(isLucky ? "吉" : "凶"))
                .help(tr(isLucky ? "吉" : "凶"))
        } else {
            Text(tr(isLucky ? "吉" : "凶")).foregroundStyle(isLucky ? lucky : .red)
        }
    }

    @ViewBuilder private var supplementaryDetails: some View {
        let rows = additionalDetails
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.feature.title).foregroundStyle(.secondary)
                        Text(row.value).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if features.contains(.seasonal), day.plumRain != nil {
                    Text(tr("按传统历法推算，并非天气预报")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(12)
            .background(DS.Palette.textSecondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var additionalDetails: [CalendarDetail] {
        var rows: [CalendarDetail] = []
        if features.contains(.holidays), let holiday = day.holiday {
            rows.append(.init(feature: .holidays, value: tr(holiday.name) + " · " + tr(holiday.isWork ? "调休上班" : "放假")))
        }
        if features.contains(.festivals), !day.festivals.isEmpty {
            rows.append(.init(feature: .festivals, value: day.festivals.map { tr($0) }.joined(separator: " · ")))
        }
        if features.contains(.solarTerms), let value = day.solarTerm { rows.append(.init(feature: .solarTerms, value: tr(value))) }
        if features.contains(.seasonal) {
            let seasons = [day.dogDays, day.plumRain, day.nineDays].compactMap { $0 }
            if !seasons.isEmpty { rows.append(.init(feature: .seasonal, value: seasons.map(tr).joined(separator: " · "))) }
        }
        return rows + CalendarEngine.additionalCalendars(for: day, features: features)
    }
}
