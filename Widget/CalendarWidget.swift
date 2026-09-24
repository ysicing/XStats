// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI
import WidgetData
import WidgetKit

struct CalendarWidgetEntry: TimelineEntry {
    let date: Date
    let firstWeekday: Int
    let showsLunar: Bool
}

struct CalendarWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalendarWidgetEntry {
        .init(date: .now, firstWeekday: 2, showsLunar: true)
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
        return .init(date: .now, firstWeekday: snapshot.calendarFirstWeekday, showsLunar: snapshot.showsLunar)
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
        VStack(alignment: .leading, spacing: 4) {
            Label(tr("日历"), systemImage: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(entry.date, format: .dateTime.day())
                .font(.system(size: 56, weight: .medium, design: .rounded))
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
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
    }

    private var monthView: some View {
        var calendar = Calendar.autoupdatingCurrent
        calendar.firstWeekday = entry.firstWeekday == 1 ? 1 : 2
        let first = calendar.dateInterval(of: .month, for: entry.date)?.start ?? entry.date
        let dayCount = calendar.range(of: .day, in: .month, for: entry.date)?.count ?? 30
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        let weekdays = formatter.veryShortStandaloneWeekdaySymbols ?? ["日", "一", "二", "三", "四", "五", "六"]
        let orderedWeekdays = (0..<7).map { weekdays[($0 + calendar.firstWeekday - 1) % 7] }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.date, format: .dateTime.year().month(.wide))
                    .font(.headline)
                Spacer()
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 1) {
                ForEach(orderedWeekdays.indices, id: \.self) { index in
                    Text(orderedWeekdays[index])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(0..<(offset + dayCount), id: \.self) { index in
                    if index < offset {
                        Color.clear.frame(height: 16)
                    } else {
                        let day = index - offset + 1
                        Text("\(day)")
                            .font(.caption2.weight(day == calendar.component(.day, from: entry.date) ? .bold : .regular))
                            .foregroundStyle(day == calendar.component(.day, from: entry.date) ? .white : .primary)
                            .frame(maxWidth: .infinity, minHeight: 16)
                            .background(day == calendar.component(.day, from: entry.date) ? Color.accentColor : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
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
        .description(tr("查看今天的日期或本月月历。"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
