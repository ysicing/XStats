// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI
import WidgetData

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
      ForEach(ClockTimeZone.allCases) { zone in
        let timeStyle = zone.timeStyle(locale: locale)
        if zone != .local { Divider() }
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Group {
              if zone == .local {
                Text(date, format: zone.locationStyle(locale: locale))
              } else {
                Text(L10n.translate(zone.title, language: language))
              }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1).minimumScaleFactor(0.75)
            Text(date, format: zone.dateStyle(locale: locale))
              .font(.system(size: 11)).foregroundStyle(.secondary)
              .lineLimit(1).minimumScaleFactor(0.8)
          }
          Spacer(minLength: 0)
          Text(date, format: timeStyle)
            .font(.system(size: 24, weight: .light)).monospacedDigit()
            .environment(\.locale, timeStyle.locale)
            .environment(\.layoutDirection, .leftToRight)
        }
        .environment(\.timeZone, zone.timeZone)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("timer-time-zone-\(zone.id)")
      }
    }
  }
}
