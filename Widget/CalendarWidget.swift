// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI
import WidgetData
import WidgetKit

struct CalendarWidgetEntry: TimelineEntry {
    let date: Date
    let showsLunar: Bool
    let showsSeasonal: Bool
    let firstWeekday: Int
    let today: WidgetSnapshot.CalendarSummary?
    let tomorrow: WidgetSnapshot.CalendarSummary?
    let month: WidgetSnapshot.MonthSummary?
}

struct CalendarWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalendarWidgetEntry {
        .init(date: .now, showsLunar: true, showsSeasonal: false, firstWeekday: 2,
              today: nil, tomorrow: nil, month: nil)
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
        let nextDay = WidgetSnapshot.keyCalendar.date(byAdding: .day, value: 1, to: now) ?? now
        return .init(date: now, showsLunar: snapshot.showsLunar, showsSeasonal: snapshot.showsSeasonal == true,
                     firstWeekday: snapshot.calendarFirstWeekday,
                     today: snapshot.calendarSummary(for: now),
                     tomorrow: snapshot.calendarSummary(for: nextDay), month: snapshot.monthSummary(for: now))
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
            if entry.showsSeasonal, let seasons = entry.today?.seasonalDescriptions, !seasons.isEmpty {
                Text(seasons.map(tr).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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
        StaticConfiguration(kind: WidgetKind.calendar, provider: CalendarWidgetProvider()) { entry in
            CalendarWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("日历"))
        .description(tr("查看今天的节日与黄历。"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct MonthCalendarWidgetView: View {
    let entry: CalendarWidgetEntry

    private var firstWeekday: Int { entry.firstWeekday == 1 ? 1 : 2 }

    private var calendar: Calendar { WidgetSnapshot.keyCalendar }
    private var monthKey: String { WidgetSnapshot.monthKey(for: entry.date) }
    private var todayKey: String { WidgetSnapshot.dayKey(for: entry.date) }

    private var days: [WidgetSnapshot.MonthDay] {
        if let month = entry.month, month.days.count == 42 { return month.days }
        let parts = calendar.dateComponents([.year, .month], from: entry.date)
        guard let year = parts.year, let month = parts.month,
              let first = calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12)) else { return [] }
        let offset = (calendar.component(.weekday, from: first) - firstWeekday + 7) % 7
        return (0..<42).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index - offset, to: first) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day,
                  let weekday = parts.weekday else { return nil }
            return WidgetSnapshot.MonthDay(dateKey: WidgetSnapshot.dayKey(year: year, month: month, day: day),
                                           number: day, subtitle: "", holidayName: nil, isWork: nil,
                                           isWeekend: weekday == 1 || weekday == 7)
        }
    }

    private var weekdays: [String] {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = calendar
        return (0..<7).map { offset in
            let weekday = (firstWeekday - 1 + offset) % 7
            return formatter.shortWeekdaySymbols[weekday]
        }
    }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "calendar").foregroundStyle(Color.accentColor)
                Text(entry.date, format: .dateTime.year().month(.wide))
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
            }
            HStack(spacing: 3) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                    Text(name).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 4) {
                ForEach(days, id: \.dateKey) { day in
                    dayCell(day)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .containerBackground(.background, for: .widget)
        .environment(\.locale, L10n.locale)
    }

    private func dayCell(_ day: WidgetSnapshot.MonthDay) -> some View {
        let isToday = day.dateKey == todayKey
        let isRest = day.isWork.map { !$0 } ?? day.isWeekend
        return VStack(spacing: 2) {
            Text(String(day.number))
                .font(.system(size: 15, weight: isToday ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isToday ? Color.white : isRest ? Color.red : Color.primary)
                .frame(width: 24, height: 24)
                .background(isToday ? Color.accentColor : .clear, in: Circle())
            Text(day.subtitle.isEmpty ? " " : tr(day.subtitle))
                .font(.system(size: 9))
                .foregroundStyle(day.holidayName == nil ? Color.secondary : Color.red)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .overlay(alignment: .topTrailing) {
            if let isWork = day.isWork {
                Text(tr(isWork ? "班" : "休"))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isWork ? Color.secondary : Color.red)
            }
        }
        .opacity(day.dateKey.hasPrefix(monthKey) ? 1 : 0.38)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([day.dateKey, tr(day.subtitle), day.isWork.map { tr($0 ? "调休上班" : "放假") }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

struct MonthCalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.calendarMonth, provider: CalendarWidgetProvider()) { entry in
            MonthCalendarWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("月历"))
        .description(tr("查看整月的公历、农历与节假日。"))
        .supportedFamilies([.systemLarge])
    }
}

private struct TomorrowWorkWidgetView: View {
    let entry: CalendarWidgetEntry

    private var needsWork: Bool? { entry.tomorrow?.schedule.needsWork }
    private var tomorrowDate: Date {
        WidgetSnapshot.keyCalendar.date(byAdding: .day, value: 1, to: entry.date) ?? entry.date
    }

    private var scheduleTitle: String? {
        guard let schedule = entry.tomorrow?.schedule else { return nil }
        return switch schedule {
        case .work: tr("工作日")
        case .weekend: entry.tomorrow?.holidayName.flatMap { $0.isEmpty ? nil : tr($0) } ?? tr("周末")
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
        StaticConfiguration(kind: WidgetKind.tomorrowWork, provider: CalendarWidgetProvider()) { entry in
            TomorrowWorkWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("明天上班吗"))
        .description(tr("查看明天是否上班或放假。"))
        .supportedFamilies([.systemSmall])
    }
}
