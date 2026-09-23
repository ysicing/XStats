// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import SwiftUI

/// 月历与黄历详情在同一个面板内切换；返回时保留浏览月份和选中的日期。
struct CalendarPopover: View {
    static let width: CGFloat = 560
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var month: CalendarMonth
    @State private var selected: CalendarDay?
    @State private var days: [CalendarDay]
    @State private var lastTodayID: String?
    @State private var showsDayDetails: Bool
    @State private var almanac: CalendarAlmanac?
    private let referenceDate: Date?

    init(referenceDate: Date? = nil, showsDayDetails: Bool = false) {
        self.referenceDate = referenceDate
        let today = CalendarEngine.today(at: referenceDate ?? Date())
        let month = CalendarMonth(year: today?.year ?? 2026, month: today?.month ?? 1)
        _month = State(initialValue: month)
        _selected = State(initialValue: today)
        _showsDayDetails = State(initialValue: showsDayDetails)
        _almanac = State(initialValue: showsDayDetails ? today.flatMap { CalendarEngine.almanac(for: $0) } : nil)
        _lastTodayID = State(initialValue: today?.id)
        _days = State(initialValue: CalendarEngine.month(year: month.year, month: month.month, firstWeekday: 2))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = CalendarEngine.today(at: referenceDate ?? context.date)
            VStack(spacing: 0) {
                Group {
                    if showsDayDetails { detailHeader(today: today) }
                    else { header(today: today) }
                }
                .padding(18)
                PageScroll {
                    VStack(spacing: 16) {
                        if showsDayDetails, let selected, let almanac {
                            CalendarAlmanacView(day: selected, almanac: almanac, features: model.settings.calendarFeatures)
                        } else {
                            calendarGrid(today: today)
                        }
                        if model.settings.calendarFeatures.contains(.holidays), !CalendarEngine.hasHolidayData(year: month.year) {
                            Text(tr("该年份暂无中国法定假日与调休数据"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .environment(\.isPopover, true)
            }
            .onChange(of: today?.id) { _, newID in
                // 正在看今天时跨日自动跟进；浏览历史日期时保留用户选择。
                if selected?.id == lastTodayID, let today {
                    selected = today
                    month = CalendarMonth(year: today.year, month: today.month)
                }
                lastTodayID = newID
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: isSnapshot ? nil : .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: isSnapshot)
        .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.xl))
        .appLanguageEnvironment()
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.xl).strokeBorder(DS.Palette.border) }
        .onAppear { reload() }
        .onChange(of: month) { _, _ in reload() }
        .onChange(of: selected?.id) { _, _ in refreshAlmanac() }
        .onChange(of: model.settings.calendarFirstWeekday) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            guard referenceDate == nil, let today = CalendarEngine.today() else { return }
            if selected?.id == lastTodayID { goToToday(today) }
            lastTodayID = today.id
        }
    }

    private func header(today: CalendarDay?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar").foregroundStyle(Color.accentColor)
            Picker(tr("年份"), selection: $month.year) {
                ForEach(CalendarMonth.years, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            Picker(tr("月份"), selection: $month.month) {
                ForEach(1...12, id: \.self) { value in Text(monthName(value)).tag(value) }
            }
            .labelsHidden().fixedSize()
            Spacer(minLength: 0)
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .help(tr("上个月")).accessibilityLabel(tr("上个月"))
                .disabled(month.shifted(by: -1) == nil)
            Button(tr("今天")) { if let today { goToToday(today) } }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .help(tr("下个月")).accessibilityLabel(tr("下个月"))
                .disabled(month.shifted(by: 1) == nil)
            Button { model.openMainWindow(.settingsMenuBar) } label: { Image(systemName: "gearshape") }
                .help(tr("日历设置…")).accessibilityLabel(tr("日历设置…"))
        }
        .buttonStyle(.borderless)
    }

    private func calendarGrid(today: CalendarDay?) -> some View {
        let features = model.settings.calendarFeatures
        let firstWeekday = model.settings.calendarFirstWeekday
        return VStack(spacing: 8) {
            if features.contains(.weekdays) {
                HStack(spacing: 4) {
                    ForEach(0..<7) { offset in
                        let weekday = (firstWeekday - 1 + offset) % 7 + 1
                        Text(weekdayName(weekday))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(weekday == 1 || weekday == 7 ? Color.red : .secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 4)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                ForEach(days) { day in
                    CalendarDayCell(day: day, features: features, isCurrentMonth: day.month == month.month,
                                    isToday: day.id == today?.id, isSelected: day.id == selected?.id) {
                        selected = day
                        if day.month != month.month, CalendarMonth.years.contains(day.year) {
                            month = CalendarMonth(year: day.year, month: day.month)
                        }
                        showsDayDetails = true
                        refreshAlmanac()
                    }
                }
            }
        }
    }

    private func detailHeader(today: CalendarDay?) -> some View {
        HStack {
            Button {
                showsDayDetails = false
            } label: {
                Label(tr("返回月历"), systemImage: "chevron.backward")
            }
            Spacer()
            Button(tr("今天")) {
                if let today { goToToday(today) }
            }
            Button { model.openMainWindow(.settingsMenuBar) } label: { Image(systemName: "gearshape") }
                .help(tr("日历设置…")).accessibilityLabel(tr("日历设置…"))
        }
        .buttonStyle(.borderless)
    }

    private func refreshAlmanac() {
        guard showsDayDetails, let selected, almanac?.id != selected.id else { return }
        almanac = CalendarEngine.almanac(for: selected)
    }

    private func reload() {
        selected = CalendarEngine.selection(selected, in: month)
        days = CalendarEngine.month(year: month.year, month: month.month, firstWeekday: model.settings.calendarFirstWeekday)
    }

    private func shift(_ delta: Int) {
        guard let next = month.shifted(by: delta) else { return }
        month = next
        selected = CalendarEngine.day(year: next.year, month: next.month, day: 1)
    }

    private func goToToday(_ today: CalendarDay) {
        month = CalendarMonth(year: today.year, month: today.month)
        selected = today
    }

    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = CalendarEngine.gregorian()
        return formatter.monthSymbols[month - 1]
    }

    private func weekdayName(_ weekday: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = CalendarEngine.gregorian()
        return formatter.shortWeekdaySymbols[weekday - 1]
    }
}

private struct CalendarDayCell: View {
    let day: CalendarDay
    let features: Set<CalendarFeature>
    let isCurrentMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let action: () -> Void

    private var holiday: CalendarDay.Holiday? { features.contains(.holidays) ? day.holiday : nil }
    private var isRest: Bool { holiday.map { !$0.isWork } ?? day.isWeekend }
    private var foreground: Color { isSelected ? .white : isRest ? .red : DS.Palette.textPrimary }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(String(day.day)).font(.system(size: 21, weight: isToday ? .semibold : .regular, design: .rounded))
                Text(tr(day.subtitle(features: features)))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if features.contains(.ganzhi) {
                    Text(day.ganzhiDay).font(.system(size: 9)).opacity(0.75)
                }
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(isSelected ? Color.accentColor : holiday != nil ? foreground.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if isToday && !isSelected { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 1.5) }
            }
            .overlay(alignment: .topTrailing) {
                if let holiday {
                    Text(tr(holiday.isWork ? "班" : "休"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(holiday.isWork ? Color.secondary : .red, in: RoundedRectangle(cornerRadius: 3))
                        .padding(2)
                } else if isToday {
                    Circle().fill(isSelected ? .white : Color.accentColor).frame(width: 5, height: 5).padding(5)
                }
            }
            .opacity(isCurrentMonth ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([day.id, features.contains(.lunar) ? day.lunarSummary : "", tr(day.subtitle(features: features)),
                             holiday.map { tr($0.isWork ? "调休上班" : "放假") } ?? "", isToday ? tr("今天") : ""]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
