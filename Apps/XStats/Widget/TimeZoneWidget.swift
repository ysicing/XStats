// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI
import WidgetData
import WidgetKit

struct TimeZoneEntry: TimelineEntry {
  let date: Date
  let language: AppLanguage
  var isPreview = false
}

struct TimeZoneProvider: TimelineProvider {
  func placeholder(in context: Context) -> TimeZoneEntry {
    TimeZoneEntry(date: .now, language: .system, isPreview: true)
  }

  func getSnapshot(in context: Context, completion: @escaping (TimeZoneEntry) -> Void) {
    completion(
      TimeZoneEntry(date: .now, language: language, isPreview: context.isPreview))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<TimeZoneEntry>) -> Void) {
    if #available(macOS 15, *) {
      completion(Self.timeline(at: .now, language: language, usesLiveClock: true))
    } else {
      completion(Self.timeline(at: .now, language: language, usesLiveClock: false))
    }
  }

  static func timeline(
    at date: Date, language: AppLanguage, usesLiveClock: Bool
  ) -> Timeline<TimeZoneEntry> {
    let current = TimeZoneEntry(date: date, language: language)
    if usesLiveClock {
      return Timeline(entries: [current], policy: .after(date.addingTimeInterval(6 * 3600)))
    }
    // macOS 14 预生成六小时的整分钟条目；不让扩展每分钟重新启动。
    let nextMinute = floor(date.timeIntervalSince1970 / 60) * 60 + 60
    let entries = (0..<360).map { minute in
      TimeZoneEntry(
        date: Date(timeIntervalSince1970: nextMinute + Double(minute) * 60), language: language)
    }
    return Timeline(entries: [current] + entries, policy: .atEnd)
  }

  private var language: AppLanguage {
    WidgetSnapshotStore().loadIfAvailable()
      .flatMap { AppLanguage(rawValue: $0.language) } ?? .system
  }
}

struct TimeZoneWidgetView: View {
  let entry: TimeZoneEntry

  var body: some View {
    VStack(spacing: 0) {
      ForEach(ClockTimeZone.allCases) { zone in
        if zone != .local { Divider() }
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Group {
              if zone == .local {
                clockText(style: zone.locationStyle(locale: locale))
              } else {
                Text(L10n.translate(zone.title, language: entry.language))
              }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1).minimumScaleFactor(0.75)
            clockText(style: zone.dateStyle(locale: locale))
              .font(.system(size: 10)).foregroundStyle(.secondary)
              .lineLimit(1).minimumScaleFactor(0.8)
          }
          Spacer(minLength: 0)
          clockText(style: zone.timeStyle(locale: locale, includesSeconds: false))
            .font(.system(size: 24, weight: .light)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.8)
            .fixedSize(horizontal: true, vertical: false)
            .environment(\.layoutDirection, .leftToRight)
        }
        .environment(\.timeZone, zone.timeZone)
        .padding(.vertical, 4)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
      }
    }
    .containerBackground(.background, for: .widget)
    .environment(\.locale, locale)
    .environment(\.layoutDirection, entry.language.isRightToLeft ? .rightToLeft : .leftToRight)
  }

  private var locale: Locale { L10n.locale(for: entry.language) }

  private func clockText(style: Date.FormatStyle) -> Text {
    if #available(macOS 15, *), !entry.isPreview {
      Text(.currentDate, format: style)
    } else {
      Text(entry.date, format: style)
    }
  }
}

struct TimeZoneWidget: Widget {
  var body: some WidgetConfiguration {
    let language =
      WidgetSnapshotStore().loadIfAvailable()
      .flatMap { AppLanguage(rawValue: $0.language) } ?? .system
    return StaticConfiguration(kind: WidgetKind.timeZones, provider: TimeZoneProvider()) { entry in
      TimeZoneWidgetView(entry: entry)
    }
    .configurationDisplayName(L10n.translate("时区", language: language))
    .description(L10n.translate("查看当地、UTC 与美西时间。", language: language))
    .supportedFamilies([.systemMedium])
  }
}
