// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI
import WidgetData
import WidgetKit

struct CalendarWidgetEntry: TimelineEntry {
    let date: Date
    let showsLunar: Bool
    let today: WidgetSnapshot.CalendarSummary?
    let tomorrow: WidgetSnapshot.CalendarSummary?
}

struct CalendarWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalendarWidgetEntry {
        .init(date: .now, showsLunar: true, today: nil, tomorrow: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (CalendarWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarWidgetEntry>) -> Void) {
        let entry = read()
        let now = entry.date
        let nextDay = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1,
                                                       to: Calendar.autoupdatingCurrent.startOfDay(for: now))
            ?? now.addingTimeInterval(24 * 60 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextDay)))
    }

    private func read() -> CalendarWidgetEntry {
        let snapshot = WidgetSnapshotStore().load()
        L10n.configure(AppLanguage(rawValue: snapshot.language) ?? .system)
        let now = Date.now
        let nextDay = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: now) ?? now
        return .init(date: now, showsLunar: snapshot.showsLunar,
                     today: snapshot.calendarSummary(for: now),
                     tomorrow: snapshot.calendarSummary(for: nextDay))
    }
}

private struct CalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CalendarWidgetEntry

    var body: some View {
        Group {
            if family == .systemMedium { monthView }
            else { dayView }
        }
        .containerBackground(.background, for: .widget)
        .environment(\.locale, L10n.locale)
    }

    private var dayView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(tr("日历"), systemImage: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(entry.date, format: .dateTime.day())
                .font(.system(size: 50, weight: .medium, design: .rounded))
                .minimumScaleFactor(0.7)
            Text(entry.date, format: .dateTime.weekday(.wide).month(.wide))
                .font(.subheadline)
                .lineLimit(1)
            if entry.showsLunar {
                Text(lunarDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let occasion = occasion {
                Text(occasion)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
    }

    private var monthView: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Label(tr("日历"), systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.date, format: .dateTime.day())
                    .font(.system(size: 50, weight: .medium, design: .rounded))
                Text(entry.date, format: .dateTime.weekday(.wide).month(.wide))
                    .font(.caption)
                    .lineLimit(1)
                if entry.showsLunar {
                    Text(lunarDate).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let occasion {
                    Text(occasion).font(.caption.weight(.medium)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(.quaternary).frame(width: 1)
            VStack(alignment: .leading, spacing: 7) {
                if let today = entry.today {
                    if let star = today.twelveStar {
                        HStack(spacing: 5) {
                            Text(tr(today.isEcliptic ? "黄道日" : "黑道日"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(today.isEcliptic ? .green : .secondary)
                            Text(star).font(.caption2).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                    advice(tr("宜"), values: today.recommends)
                    advice(tr("忌"), values: today.avoids)
                } else {
                    Text(tr("暂无安排")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    private func advice(_ title: String, values: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(values.isEmpty ? tr("无") : values.joined(separator: " · "))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption2)
    }

    private var occasion: String? {
        if let festival = entry.today?.festivals.first { return tr(festival) }
        if let term = entry.today?.solarTerm { return tr(term) }
        return nil
    }

    private var lunarDate: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .chinese)
        formatter.locale = L10n.locale
        formatter.dateFormat = "MMMMd"
        return formatter.string(from: entry.date)
    }
}

struct CalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "work.12306.xstats.widget.calendar", provider: CalendarWidgetProvider()) { entry in
            CalendarWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("日历"))
        .description(tr("查看今天的节日与黄历。"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct TomorrowWorkWidgetView: View {
    let entry: CalendarWidgetEntry

    private var needsWork: Bool? { entry.tomorrow?.schedule.needsWork }
    private var tomorrowDate: Date {
        Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: entry.date) ?? entry.date
    }

    private var scheduleTitle: String? {
        guard let schedule = entry.tomorrow?.schedule else { return nil }
        return switch schedule {
        case .work: tr("工作日")
        case .weekend: tr("周末")
        case .holiday: entry.tomorrow?.holidayName.flatMap { $0.isEmpty ? nil : tr($0) } ?? tr("节假日")
        case .makeupWork: tr("调休补班")
        case .makeupDayOff: tr("调休放假")
        case .dayOff: tr("放假")
        case .unknown: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("明天上班吗"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(tomorrowDate, format: .dateTime.month(.abbreviated).day().weekday(.abbreviated))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if let needsWork {
                Text(tr(needsWork ? "上班" : "不上班"))
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let scheduleTitle {
                    Text(scheduleTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            } else {
                Text(tr("暂无法判断"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .containerBackground(.background, for: .widget)
        .environment(\.locale, L10n.locale)
        .accessibilityElement(children: .combine)
    }
}

struct TomorrowWorkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "work.12306.xstats.widget.tomorrowWork", provider: CalendarWidgetProvider()) { entry in
            TomorrowWorkWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("明天上班吗"))
        .description(tr("查看明天是否上班或放假。"))
        .supportedFamilies([.systemSmall])
    }
}
