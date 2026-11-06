// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

enum TimerTimeZone: String, CaseIterable, Identifiable {
  case local
  case utc = "UTC"
  case pacific = "America/Los_Angeles"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .local: "当地时间"
    case .utc: "UTC 时间"
    case .pacific: "美西时间"
    }
  }

  var timeZone: TimeZone {
    self == .local ? .autoupdatingCurrent : TimeZone(identifier: rawValue)!
  }

  func time(at date: Date, locale: Locale) -> String {
    date.formatted(
      Date.FormatStyle(
        date: .omitted, time: .omitted, locale: locale, timeZone: timeZone
      ).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits).second(.twoDigits))
  }

  func calendarDate(at date: Date, locale: Locale) -> String {
    date.formatted(
      Date.FormatStyle(
        date: .omitted, time: .omitted, locale: locale, timeZone: timeZone
      ).year().month(.abbreviated).day())
  }
}

struct TimerTimeZoneContent: View {
  var language: AppLanguage
  @Environment(\.isSnapshot) private var isSnapshot
  @Environment(\.locale) private var locale

  var body: some View {
    // 时间线仅挂载在当前页；切页或关闭面板后停止刷新，测量和截图不调度刷新。
    if isSnapshot {
      clocks(at: .now)
    } else {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        clocks(at: context.date)
      }
    }
  }

  private func clocks(at date: Date) -> some View {
    VStack(spacing: 0) {
      ForEach(TimerTimeZone.allCases) { zone in
        if zone != .local { Divider() }
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(L10n.translate(zone.title, language: language))
              .font(.system(size: 12, weight: .medium))
            Text(zone.calendarDate(at: date, locale: locale))
              .font(.system(size: 11)).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          Text(zone.time(at: date, locale: locale))
            .font(.system(size: 24, weight: .light)).monospacedDigit()
            .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("timer-time-zone-\(zone.id)")
      }
    }
  }
}
