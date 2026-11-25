// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

struct ActivityPageTimeline: View {
  let report: ActivityPageAnalytics
  let interval: DateInterval
  let period: ActivityPagePeriod
  let calendar: Calendar
  let locale: Locale
  let combinesDevices: Bool

  var body: some View {
    Card(spacing: DS.Space.s4) {
      VStack(alignment: .leading, spacing: DS.Space.s2) {
        Text(combinesDevices ? tr("活跃时长（设备累计）") : tr("活跃时长"))
          .foregroundStyle(.secondary)
          .help(combinesDevices ? tr("各设备的活跃分钟分别计算后相加") : tr("活跃时长"))
        Text(ActivityPageFormat.duration(report.seconds, locale: locale))
          .font(.system(size: 34, weight: .semibold))
          .monospacedDigit()
      }
      .accessibilityElement(children: .combine)

      if period == .day {
        dayTimeline
      } else {
        dailyBars
      }

      if !report.categories.isEmpty {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: DS.Space.s3) { legend }
            .fixedSize(horizontal: true, vertical: false)
          VStack(alignment: .leading, spacing: DS.Space.s1) { legend }
        }
        .font(.caption)
      }
    }
  }

  private var dayTimeline: some View {
    VStack(spacing: DS.Space.s2) {
      Canvas { context, size in
        let laneHeight = size.height / CGFloat(max(1, report.lanes.count))
        let barHeight = min(20, laneHeight * 0.8)
        let radius = min(barHeight / 2, 2)
        for (index, lane) in report.lanes.enumerated() {
          let y = laneHeight * CGFloat(index) + (laneHeight - barHeight) / 2
          for segment in lane.segments {
            let x = size.width * segment.start.timeIntervalSince(interval.start) / interval.duration
            let width = size.width * segment.seconds / interval.duration
            let rectangle = CGRect(x: x, y: y, width: width, height: barHeight)
            context.fill(
              Path(roundedRect: rectangle, cornerRadius: min(radius, width / 2)),
              with: .color(segment.category.color))
          }
        }
      }
      .frame(height: min(100, 24 * CGFloat(max(1, report.lanes.count))))
      HStack {
        ForEach(0...4, id: \.self) { index in
          if index != 0 { Spacer(minLength: DS.Space.s1) }
          let tick = interval.start.addingTimeInterval(interval.duration * Double(index) / 4)
          Text(ActivityPageFormat.time(tick, calendar: calendar, locale: locale))
            .lineLimit(1)
        }
      }
      .font(.caption)
      .monospacedDigit()
      .foregroundStyle(.secondary)
    }
    .environment(\.layoutDirection, .leftToRight)
    .accessibilityHidden(true)
  }

  private var dailyBars: some View {
    let maximum = max(1, report.days.map(\.seconds).max() ?? 0)
    let dateStyle = Date.FormatStyle(
      locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    return HStack(alignment: .top, spacing: DS.Space.s1) {
      ForEach(Array(report.days.enumerated()), id: \.element.id) { index, day in
        VStack(spacing: DS.Space.s2) {
          VStack(spacing: 0) {
            ForEach(ActivityPageAnalytics.Category.allCases, id: \.self) { category in
              if let seconds = day.secondsByCategory[category] {
                Rectangle().fill(category.color)
                  .frame(height: 84 * seconds / maximum)
              }
            }
          }
          .clipShape(.rect(cornerRadius: 3))
          .frame(height: 84, alignment: .bottom)
          if period == .week || index.isMultiple(of: 7) {
            Text(day.id.formatted(period == .week ? dateStyle.weekday(.narrow) : dateStyle.day()))
              .font(.caption2)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.id.formatted(dateStyle.month().day().weekday()))
        .accessibilityValue(ActivityPageFormat.duration(day.seconds, locale: locale))
        .help(ActivityPageFormat.duration(day.seconds, locale: locale))
      }
    }
    .foregroundStyle(.secondary)
    .environment(\.layoutDirection, .leftToRight)
  }

  private var legend: some View {
    ForEach(report.categories) { category in
      HStack(spacing: DS.Space.s1) {
        Circle().fill(category.id.color).frame(width: 7, height: 7)
          .accessibilityHidden(true)
        Text(category.id.title)
      }
    }
  }
}

struct ActivityPageAppRow: View {
  let app: ActivityPageAnalytics.App
  let maximum: TimeInterval
  let locale: Locale
  @State private var icon: Image?

  var body: some View {
    HStack(spacing: DS.Space.s3) {
      (icon ?? Image(systemName: "app"))
        .resizable().scaledToFit().frame(width: 28, height: 28)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      ActivityPageRank(
        title: app.name, color: app.category.color, seconds: app.seconds,
        maximum: maximum, locale: locale)
      Image(systemName: "chevron.forward")
        .font(.caption).foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, DS.Space.s4)
    .padding(.vertical, DS.Space.s2)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .task(id: app.id) {
      let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)?.path
      icon = path.map { AppIconCache.shared.image(bundlePath: $0) }
    }
  }
}

struct ActivityPageRank: View {
  let title: String
  let color: Color
  let seconds: TimeInterval
  let maximum: TimeInterval
  let locale: Locale

  var body: some View {
    HStack(spacing: DS.Space.s3) {
      Text(verbatim: title)
        .fontWeight(.medium)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 76, maxWidth: 116, alignment: .leading)
      GeometryReader { proxy in
        Capsule().fill(color)
          .frame(width: maximum > 0 ? proxy.size.width * seconds / maximum : 0)
      }
      .frame(height: 5)
      .accessibilityHidden(true)
      Text(ActivityPageFormat.duration(seconds, locale: locale))
        .monospacedDigit()
        .fixedSize()
    }
  }
}

struct ActivityPageSegments: View {
  @Environment(\.dismiss) private var dismiss
  let app: ActivityPageAnalytics.App
  let localID: UUID
  let deviceNames: [UUID: String]
  let showsDevice: Bool
  let locale: Locale

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack {
        VStack(alignment: .leading) {
          Text(verbatim: app.name).font(.title2).fontWeight(.semibold)
          Text(tr("活动时段")).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Text(ActivityPageFormat.duration(app.seconds, locale: locale))
          .monospacedDigit().foregroundStyle(.secondary)
      }
      List(app.segments) { segment in
        HStack(spacing: DS.Space.s2) {
          Circle().fill(segment.category.color).frame(width: 7, height: 7)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(ActivityPageFormat.segmentTimes(segment, locale: locale))
            if showsDevice {
              Text(
                verbatim: ActivityPageFormat.deviceName(
                  segment.deviceID, localID: localID, names: deviceNames)
              )
              .font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Text(ActivityPageFormat.duration(segment.seconds, locale: locale))
            .monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
      HStack {
        Spacer()
        Button(tr("完成")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(DS.Space.s4)
    .frame(width: 540, height: 440)
  }
}

enum ActivityPageFormat {
  static func duration(_ seconds: TimeInterval, locale: Locale) -> String {
    let units: Set<Duration.UnitsFormatStyle.Unit> =
      seconds >= 60 ? [.hours, .minutes] : [.seconds]
    return Duration.seconds(seconds.rounded(.down)).formatted(
      .units(allowed: units, width: .wide).locale(locale))
  }

  static func dateTitle(
    _ interval: DateInterval, period: ActivityPagePeriod, calendar: Calendar, locale: Locale
  ) -> String {
    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    switch period {
    case .day:
      return interval.start.formatted(style.year().month().day().weekday(.wide))
    case .week:
      let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
      return (interval.start..<end).formatted(
        Date.IntervalFormatStyle(
          date: .abbreviated, time: .omitted, locale: locale,
          calendar: calendar, timeZone: calendar.timeZone))
    case .month:
      return interval.start.formatted(style.year().month(.wide))
    }
  }

  static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
    date.formatted(
      Date.FormatStyle(
        date: .omitted, time: .shortened, locale: locale, calendar: calendar,
        timeZone: calendar.timeZone))
  }

  static func segmentTimes(_ segment: ActivityPageAnalytics.Segment, locale: Locale) -> String {
    (segment.start..<segment.end).formatted(
      Date.IntervalFormatStyle(date: .abbreviated, time: .shortened, locale: locale))
  }

  static func deviceName(_ id: UUID, localID: UUID, names: [UUID: String]) -> String {
    let shortID = String(id.uuidString.prefix(8))
    if let name = names[id] {
      return names.contains { $0.key != id && $0.value == name } ? "\(name) · \(shortID)" : name
    }
    if id == localID { return tr("本机（\(shortID)）") }
    return tr("设备 \(shortID)")
  }
}

extension ActivityPageAnalytics.Category {
  var title: String {
    switch self {
    case .work: tr("工作")
    case .entertainment: tr("娱乐")
    case .communication: tr("沟通")
    case .browsing: tr("浏览")
    case .other: tr("其他")
    }
  }

  var color: Color {
    switch self {
    case .work: .indigo
    case .entertainment: .orange
    case .communication: .teal
    case .browsing: .blue
    case .other: .gray
    }
  }
}
