// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

struct ActivityPageTimeline<Navigation: View>: View {
  let report: ActivityPageAnalytics
  let interval: DateInterval
  let period: ActivityPagePeriod
  let calendar: Calendar
  let locale: Locale
  let combinesDevices: Bool
  let now: Date
  let animateEntry: Bool
  let deviceNames: [UUID: String]
  let localID: UUID
  let openDay: (Date) -> Void
  @ViewBuilder let navigation: () -> Navigation

  @State private var showsSessions = false
  @State private var entered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isSnapshot) private var isSnapshot

  var body: some View {
    Card(spacing: DS.Space.s4) {
      navigation()
      VStack(alignment: .leading, spacing: DS.Space.s2) {
        Text(ActivityPageFormat.duration(report.seconds, locale: locale))
          .font(.system(size: 34, weight: .semibold))
          .monospacedDigit()
        Text(combinesDevices ? tr("设备累计") : tr("活跃时长"))
          .foregroundStyle(.secondary)
          .help(combinesDevices ? tr("各设备的活跃分钟分别计算后相加") : tr("活跃时长"))
      }
      .accessibilityElement(children: .combine)

      Group {
        if period == .week {
          weekRows
        } else {
          ActivityPeriodChart(
            buckets: period == .day ? report.hours : report.days, hourly: period == .day,
            now: now, calendar: calendar, locale: locale, openDay: openDay)
        }
      }
      .opacity(animateEntry && !entered && !reduceMotion && !isSnapshot ? 0 : 1)
      .task {
        guard animateEntry, !reduceMotion, !isSnapshot else { return }
        withAnimation(DS.Motion.quick) { entered = true }
      }

      if !report.categories.isEmpty {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: DS.Space.s3) { legend }
            .fixedSize(horizontal: true, vertical: false)
          VStack(alignment: .leading, spacing: DS.Space.s1) { legend }
        }
        .font(.caption)
      }

      if period == .day, !report.lanes.isEmpty {
        Divider()
        DisclosureGroup(tr("活动时段"), isExpanded: $showsSessions) {
          VStack(alignment: .leading, spacing: DS.Space.s3) {
            ForEach(report.lanes) { lane in
              if combinesDevices {
                Text(ActivityPageFormat.deviceName(lane.id, localID: localID, names: deviceNames))
                  .font(.caption).foregroundStyle(.secondary)
              }
              dayTimeline(lane)
            }
          }
          .padding(.top, DS.Space.s2)
        }
      }
    }
  }

  private func dayTimeline(_ lane: ActivityPageAnalytics.Lane) -> some View {
    VStack(spacing: DS.Space.s2) {
      Canvas { context, size in
        for segment in lane.segments {
          let x = size.width * segment.start.timeIntervalSince(interval.start) / interval.duration
          let width = size.width * segment.seconds / interval.duration
          let rectangle = CGRect(x: x, y: 0, width: width, height: size.height)
          context.fill(
            Path(roundedRect: rectangle, cornerRadius: min(2, width / 2)),
            with: .color(segment.category.color))
        }
      }
      .frame(height: 16)
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

  private var weekRows: some View {
    let maximum = report.days.lazy.filter { $0.id <= now }.map(\.seconds).max() ?? 0
    let ceiling = max(1, ceil(maximum / 3_600)) * 3_600
    let dateStyle = Date.FormatStyle(
      locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    return Grid(alignment: .leading, horizontalSpacing: DS.Space.s3, verticalSpacing: DS.Space.s2) {
      ForEach(report.days) { day in
        let future = day.id > now
        let title = day.id.formatted(dateStyle.weekday(.abbreviated).day())
        let duration = future ? "—" : ActivityPageFormat.duration(day.seconds, locale: locale)
        GridRow {
          Text(title)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(future ? .tertiary : .primary)
            .accessibilityHidden(day.seconds > 0 && !future)
          if !future, day.seconds > 0 {
            Button {
              openDay(day.id)
            } label: {
              ActivityCategoryStack(
                seconds: day.secondsByCategory, scale: ceiling, axis: .horizontal
              )
              .background(.secondary.opacity(0.12))
              .clipShape(Capsule())
              .frame(height: 12)
              .padding(.vertical, DS.Space.s1)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(duration)
            .accessibilityHint(tr("查看当天"))
            .help(tr("查看当天"))
          } else {
            Capsule().fill(future ? .clear : .secondary.opacity(0.12))
              .frame(height: 12)
              .padding(.vertical, DS.Space.s1)
              .accessibilityHidden(true)
          }
          Text(duration)
            .foregroundStyle(future ? .tertiary : .secondary)
            .lineLimit(1)
            .fixedSize()
            .gridColumnAlignment(.trailing)
            .accessibilityHidden(day.seconds > 0 && !future)
        }
      }
    }
    .font(.subheadline)
    .monospacedDigit()
  }

  private var legend: some View {
    ForEach(
      ActivityPageAnalytics.Category.allCases.filter { id in
        report.categories.contains { $0.id == id }
      }, id: \.self
    ) { category in
      HStack(spacing: DS.Space.s1) {
        Circle().fill(category.color).frame(width: 7, height: 7)
          .accessibilityHidden(true)
        Text(category.title)
      }
    }
  }
}

struct ActivityPageRankings: View {
  let report: ActivityPageAnalytics
  let locale: Locale
  let openApp: (ActivityPageAnalytics.App) -> Void
  @State private var showsAllApps = false
  @State var expandedCategories = Set<ActivityPageAnalytics.Category>()

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: DS.Space.s4) {
        apps.frame(minWidth: 282, idealWidth: 282, maxWidth: .infinity)
        categories.frame(minWidth: 282, idealWidth: 282, maxWidth: .infinity)
      }
      VStack(spacing: DS.Space.s4) {
        apps
        categories
      }
    }
  }

  private var apps: some View {
    Card(spacing: DS.Space.s2) {
      Text(tr("最常用应用")).font(.headline).accessibilityAddTraits(.isHeader)
      Divider()
      LazyVStack(spacing: 0) {
        ForEach(report.apps.prefix(showsAllApps ? report.apps.count : 5)) { app in
          if app.id != report.apps.first?.id { Divider() }
          Button {
            openApp(app)
          } label: {
            ActivityPageAppRow(app: app, locale: locale)
          }
          .buttonStyle(.plain)
        }
      }
      if report.apps.count > 5 {
        Button(tr(showsAllApps ? "收起" : "查看全部应用")) { showsAllApps.toggle() }
          .frame(maxWidth: .infinity)
      }
    }
  }

  private var categories: some View {
    let entries = report.categories.map {
      ActivityPageRank.Entry(
        id: $0.id, title: $0.id.title, color: $0.id.color, seconds: $0.seconds,
        breakdown: $0.breakdown)
    }
    return Card(spacing: DS.Space.s2) {
      Text(tr("分类占比")).font(.headline).accessibilityAddTraits(.isHeader)
      Divider()
      ViewThatFits(in: .horizontal) {
        ActivityPageRank(
          entries: entries, total: report.seconds, locale: locale, stacksDuration: false,
          expanded: $expandedCategories
        )
        .frame(minWidth: 330)
        ActivityPageRank(
          entries: entries, total: report.seconds, locale: locale, stacksDuration: true,
          expanded: $expandedCategories)
      }
    }
  }
}

private struct ActivityPageAppRow: View {
  let app: ActivityPageAnalytics.App
  let locale: Locale
  @State private var icon: Image?

  var body: some View {
    HStack(spacing: DS.Space.s3) {
      (icon ?? Image(systemName: "app"))
        .resizable().scaledToFit().frame(width: 28, height: 28)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(app.name)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Text(ActivityPageFormat.duration(app.seconds, locale: locale))
        .monospacedDigit()
        .fixedSize()
      Image(systemName: "chevron.forward")
        .font(.caption).foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
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
  struct Entry: Identifiable {
    let id: ActivityPageAnalytics.Category
    let title: String
    let color: Color
    let seconds: TimeInterval
    var breakdown: [ActivityClassification: TimeInterval] = [:]
  }

  let entries: [Entry]
  let total: TimeInterval
  let locale: Locale
  let stacksDuration: Bool
  @Binding var expanded: Set<ActivityPageAnalytics.Category>

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: DS.Space.s3, verticalSpacing: DS.Space.s2) {
      ForEach(entries) { entry in
        let fraction = total > 0 ? entry.seconds / total : 0
        let percentage = fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        let duration = ActivityPageFormat.duration(entry.seconds, locale: locale)
        GridRow {
          Group {
            if !entry.breakdown.isEmpty && entry.id != .communication && entry.id != .browsing {
              Button {
                if expanded.contains(entry.id) {
                  expanded.remove(entry.id)
                } else {
                  expanded.insert(entry.id)
                }
              } label: {
                HStack(spacing: DS.Space.s1) {
                  Image(
                    systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.forward"
                  )
                  .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                  Text(verbatim: entry.title)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityHint(expanded.contains(entry.id) ? tr("收起") : tr("展开"))
            } else {
              Text(verbatim: entry.title)
            }
          }
          .fontWeight(.medium)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 116, alignment: .leading)
          GeometryReader { proxy in
            Capsule().fill(.secondary.opacity(0.12)).overlay(alignment: .leading) {
              Capsule().fill(entry.color).frame(width: proxy.size.width * fraction)
            }
          }
          .frame(height: 5)
          .accessibilityHidden(true)
          if stacksDuration {
            VStack(alignment: .trailing, spacing: DS.Space.s1) {
              Text(percentage)
              Text(duration).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize()
            .gridColumnAlignment(.trailing)
          } else {
            Text(percentage)
              .fixedSize()
              .gridColumnAlignment(.trailing)
            Text(duration)
              .foregroundStyle(.secondary)
              .fixedSize()
              .gridColumnAlignment(.trailing)
          }
        }
        if expanded.contains(entry.id) {
          ForEach(
            entry.breakdown.keys.sorted {
              let lhs = entry.breakdown[$0, default: 0]
              let rhs = entry.breakdown[$1, default: 0]
              return lhs == rhs ? $0.rawValue < $1.rawValue : lhs > rhs
            }, id: \.self
          ) { detail in
            HStack {
              Text(detail.title)
              Spacer()
              Text(ActivityPageFormat.duration(entry.breakdown[detail, default: 0], locale: locale))
                .fixedSize()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.leading, DS.Space.s4)
            .gridCellColumns(stacksDuration ? 3 : 4)
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
    .monospacedDigit()
  }
}

struct ActivityPageSegments: View {
  @Environment(\.dismiss) private var dismiss
  let app: ActivityPageAnalytics.App
  let localID: UUID
  let deviceNames: [UUID: String]
  let showsDevice: Bool
  let locale: Locale
  var load: (() async throws -> ActivityPageAnalytics.App?)?
  @State private var details: ActivityPageAnalytics.App?
  @State private var didLoad = false
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack {
        VStack(alignment: .leading) {
          Text(verbatim: app.name).font(.title2).fontWeight(.semibold)
          Text(tr("活动时段")).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Text(
          ActivityPageFormat.duration(
            details?.seconds ?? (didLoad ? 0 : app.seconds), locale: locale)
        )
        .monospacedDigit().foregroundStyle(.secondary)
      }
      if load != nil && !didLoad && !failed {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if failed {
        Label(tr("无法读取活动记录"), systemImage: "exclamationmark.circle")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if didLoad && details == nil {
        Label(tr("此时段无活动记录"), systemImage: "clock")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        segments
      }
      HStack {
        Spacer()
        Button(tr("完成")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(DS.Space.s4)
    .frame(width: 540, height: 440)
    .task {
      guard let load else { return }
      do {
        let loaded = try await load()
        try Task.checkCancellation()
        details = loaded
        didLoad = true
      } catch {
        if !Task.isCancelled { failed = true }
      }
    }
  }

  private var segments: some View {
    List((details ?? app).segments) { segment in
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
    case .work: .blue
    case .entertainment: .orange
    case .communication: .indigo
    case .browsing: .teal
    case .other: .gray
    }
  }
}

extension ActivityClassification {
  var title: String {
    switch self {
    case .programming: tr("编程")
    case .office: tr("办公")
    case .design: tr("设计")
    case .learning: tr("学习")
    case .games: tr("游戏")
    case .media: tr("音乐与视频")
    case .utilities: tr("系统工具")
    case .other: tr("待分类")
    case .work, .entertainment: tr("未细分")
    case .communication, .browsing: category.title
    }
  }
}
