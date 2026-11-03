// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import SwiftUI

/// 日期详情按显示偏好分区；其他历法沿用各自的功能开关。
struct CalendarAlmanacView: View {
  let day: CalendarDay
  let almanac: CalendarAlmanac?
  let features: Set<CalendarFeature>
  var preferences = CalendarPreferences()
  private let lucky = Color.dynamic(light: 0x288B3B, dark: 0x63CC76)

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 8) {
        Text(dateTitle).font(.system(size: 13)).foregroundStyle(.secondary)
        if features.contains(.lunar) {
          Text(day.lunarSummary).font(.system(size: 21, weight: .semibold))
            .foregroundStyle(DS.Palette.textPrimary)
        }
        if preferences.showAlmanacDetails, let almanac {
          Text(almanac.ganzhiSummary).font(.system(size: 13)).foregroundStyle(.secondary)
        }
      }
      if let almanac {
        if preferences.showAlmanacAdvice {
          VStack(alignment: .leading, spacing: 12) {
            advice(tr("宜"), entries: almanac.recommends, color: lucky)
            advice(tr("忌"), entries: almanac.avoids, color: .red)
          }
        }
        if preferences.showAlmanacDetails {
          HStack(alignment: .top, spacing: 12) {
            tile(tr("纳音")) { Text(almanac.sound) }
            tile(tr("冲煞")) { Text(tr("冲\(almanac.opposingZodiac) 煞\(almanac.ominousDirection)")) }
            tile(tr("值神")) {
              HStack(spacing: 4) {
                Text(almanac.twelveStar)
                luckLabel(almanac.twelveStarIsLucky)
              }
            }
          }
        }
        if preferences.showAlmanacHours {
          hourTable(almanac)
        }
        if preferences.showAlmanacDetails {
          almanacDetails(almanac)
        }
      }
      supplementaryDetails
    }
    .padding(.bottom, 6)
    .textSelection(.enabled)
  }

  private var dateTitle: String {
    let formatter = DateFormatter()
    formatter.locale = L10n.locale
    formatter.calendar = CalendarEngine.gregorian()
    formatter.setLocalizedDateFormatFromTemplate("yMMMMdEEEE")
    return formatter.string(from: day.date)
  }

  private func advice(_ label: String, entries: [String], color: Color) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
        .frame(minWidth: 24, minHeight: 24)
        .padding(.horizontal, 4)
        .background(color.opacity(0.1), in: Capsule())
      Text(entries.isEmpty ? tr("无") : entries.joined(separator: "  "))
        .font(.system(size: 13)).foregroundStyle(DS.Palette.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 3)
    }
  }

  private func almanacDetails(_ almanac: CalendarAlmanac) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Divider()
      HStack(alignment: .top, spacing: 20) {
        tile(tr("建除十二神")) { Text(almanac.duty) }
        tile(tr("二十八星宿")) {
          HStack(spacing: 6) {
            Text(almanac.star)
            luckLabel(almanac.starIsLucky)
          }
        }
      }
      HStack(alignment: .top, spacing: 20) {
        tile(tr("吉神宜趋")) { Text(almanac.luckyGods.joined(separator: "  ")) }
        tile(tr("凶神宜忌")) { Text(almanac.unluckyGods.joined(separator: "  ")) }
      }
      tile(tr("今日胎神")) { Text(almanac.fetus) }
      tile(tr("彭祖百忌")) { Text(almanac.pengZu.joined(separator: "\n")) }
    }
  }

  private func hourTable(_ almanac: CalendarAlmanac) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider()
      Text(tr("时辰吉凶"))
        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
        .help(tr("子时显示当日早子时；23 点起的晚子时按次日干支计算"))
      Grid(horizontalSpacing: 6, verticalSpacing: 14) {
        ForEach(0..<2) { row in
          GridRow {
            ForEach(almanac.hours.dropFirst(row * 6).prefix(6)) { hour in
              VStack(spacing: 5) {
                Text(hour.stem + hour.branch).font(.system(size: 13, weight: .medium))
                Text(hour.timeRange).font(.system(size: 10)).monospacedDigit()
                  .foregroundStyle(.secondary)
                  .environment(\.layoutDirection, .leftToRight)
                luckLabel(hour.isLucky, compact: true).font(.system(size: 11))
              }
              .frame(maxWidth: .infinity)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(
                "\(hour.stem)\(hour.branch) \(hour.timeRange) \(tr(hour.isLucky ? "吉" : "凶"))")
            }
          }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func tile<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
      content().font(.system(size: 13)).foregroundStyle(DS.Palette.textPrimary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
        if features.contains(.seasonalInfo), day.plumRain != nil {
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
      rows.append(
        .init(
          feature: .holidays, value: tr(holiday.name) + " · " + tr(holiday.isWork ? "调休上班" : "放假")))
    }
    if features.contains(.festivals), !day.festivals.isEmpty {
      rows.append(
        .init(feature: .festivals, value: day.festivals.map { tr($0) }.joined(separator: " · ")))
    }
    if features.contains(.seasonalInfo) {
      let values = [day.solarTerm, day.dogDays, day.plumRain, day.nineDays].compactMap { $0 }
      if !values.isEmpty {
        rows.append(.init(feature: .seasonalInfo, value: values.map(tr).joined(separator: " · ")))
      }
    }
    return rows + CalendarEngine.additionalCalendars(for: day, features: features)
  }
}
