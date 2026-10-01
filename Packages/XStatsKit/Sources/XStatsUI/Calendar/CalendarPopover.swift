// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import EventKit
import Localization
import SwiftUI

/// 菜单栏月历随当前显示器的可用区域缩放；额外卡片超出高度时在面板内滚动。
struct CalendarPopoverSizing: Equatable {
    let width: CGFloat
    let cellHeight: CGFloat
    let dayFontSize: CGFloat
    let subtitleFontSize: CGFloat
    let headerPadding: CGFloat
    let sectionSpacing: CGFloat
    let maxHeight: CGFloat

    static let standard = fitting(visibleSize: CGSize(width: 1920, height: 1080))

    static func fitting(visibleSize: CGSize) -> Self {
        let compact = visibleSize.width < 1100 || visibleSize.height < 850
        let width = min(compact ? 460 : 520, max(1, visibleSize.width - 2 * DS.Space.s2))
        let maxHeight = min(640, max(360, visibleSize.height * 0.72),
                            max(1, visibleSize.height - DS.Space.s2))
        return .init(width: width, cellHeight: compact ? 48 : 56,
                     dayFontSize: compact ? 17 : 19, subtitleFontSize: compact ? 9 : 10,
                     headerPadding: compact ? 14 : 16, sectionSpacing: compact ? 12 : 14,
                     maxHeight: maxHeight)
    }
}

/// 月历与黄历详情在同一个面板内切换；返回月历时恢复今天。
struct CalendarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var month: CalendarMonth
    @State private var yearInput: String
    @FocusState private var yearFocused: Bool
    @State private var selected: CalendarDay?
    @State private var days: [CalendarDay]
    @State private var lastTodayID: String?
    @State private var showsDayDetails: Bool
    @State private var almanac: CalendarAlmanac?
    @State private var holidayPlan: CalendarHolidayPlan?
    private let referenceDate: Date?
    private let sizing: CalendarPopoverSizing

    init(referenceDate: Date? = nil, showsDayDetails: Bool = false,
         sizing: CalendarPopoverSizing = .standard, firstWeekday: Int) {
        self.referenceDate = referenceDate
        self.sizing = sizing
        let today = CalendarEngine.today(at: referenceDate ?? Date())
        let month = CalendarMonth(year: today?.year ?? 2026, month: today?.month ?? 1)
        _month = State(initialValue: month)
        _yearInput = State(initialValue: String(month.year))
        _selected = State(initialValue: today)
        _showsDayDetails = State(initialValue: showsDayDetails)
        _almanac = State(initialValue: nil)
        _lastTodayID = State(initialValue: today?.id)
        _days = State(initialValue: CalendarEngine.month(year: month.year, month: month.month, firstWeekday: firstWeekday))
        _holidayPlan = State(initialValue: nil)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = CalendarEngine.today(at: referenceDate ?? context.date)
            VStack(spacing: 0) {
                Group {
                    if showsDayDetails { detailHeader(today: today) }
                    else { header(today: today) }
                }
                .padding(sizing.headerPadding)
                // 打开时由测量视图确定高度；内容变化只滚动，避免布局回调反向调整窗口。
                Group {
                    if isSnapshot {
                        calendarContent(today: today)
                    } else {
                        ScrollView {
                            calendarContent(today: today).overlayScrollers()
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
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
                refreshHolidayPlan(at: referenceDate ?? context.date)
            }
        }
        .frame(width: isSnapshot ? sizing.width : nil)
        .frame(maxWidth: isSnapshot ? nil : .infinity)
        .frame(maxHeight: isSnapshot ? nil : .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: isSnapshot)
        .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.xl))
        .appLanguageEnvironment()
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.xl).strokeBorder(DS.Palette.border) }
        .onAppear {
            reload()
            refreshAlmanac()
            refreshHolidayPlan(at: referenceDate ?? Date())
            if !isSnapshot { model.calendarAgenda.refreshAuthorization() }
        }
        .task(id: agendaQuery) {
            guard !isSnapshot else { return }
            await model.calendarAgenda.load(agendaQuery)
        }
        .onDisappear { if !isSnapshot { model.calendarAgenda.clear() } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            if !isSnapshot && (model.settings.calendarPreferences.showEvents || model.settings.calendarPreferences.showReminders) {
                model.calendarAgenda.storeChanged()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !isSnapshot { model.calendarAgenda.refreshAuthorization() }
        }
        .onChange(of: month) { _, newMonth in
            yearInput = String(newMonth.year)
            reload()
            refreshHolidayPlan(at: referenceDate ?? Date())
        }
        .onChange(of: selected?.id) { _, _ in refreshAlmanac() }
        .onChange(of: model.settings.calendarFeatures) { _, _ in refreshHolidayPlan(at: referenceDate ?? Date()) }
        .onChange(of: model.settings.calendarPreferences.showHolidayOverview) { _, _ in
            refreshHolidayPlan(at: referenceDate ?? Date())
        }
        .onChange(of: model.settings.calendarFirstWeekday) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            reload()
            refreshHolidayPlan(at: referenceDate ?? Date())
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            guard referenceDate == nil, let today = CalendarEngine.today() else { return }
            if selected?.id == lastTodayID { goToToday(today) }
            lastTodayID = today.id
        }
    }

    private func calendarContent(today: CalendarDay?) -> some View {
        VStack(spacing: sizing.sectionSpacing) {
            if showsDayDetails, let selected {
                // 挂载前的测量尚未触发 onAppear，须同步准备详情，首次高度才能包含完整内容。
                let displayedAlmanac = isSnapshot ? CalendarEngine.almanac(for: selected) : almanac
                CalendarAlmanacView(day: selected, almanac: displayedAlmanac, features: model.settings.calendarFeatures)
                if model.settings.calendarPreferences.showEvents || model.settings.calendarPreferences.showReminders {
                    CalendarAgendaView(day: selected)
                }
            } else {
                calendarGrid(today: today)
            }
            if !showsDayDetails, let selected, model.settings.calendarPreferences.showEvents || model.settings.calendarPreferences.showReminders {
                CalendarAgendaView(day: selected)
            }
            if !showsDayDetails, model.settings.calendarFeatures.contains(.holidays),
               model.settings.calendarPreferences.showHolidayOverview,
               CalendarEngine.hasHolidayData(year: month.year) {
                // 与实际显示共用开关和年份边界；关闭概览时不为测量查询假期。
                let displayedPlan = isSnapshot
                    ? CalendarEngine.holidayPlan(from: referenceDate ?? Date(), displayedYear: month.year)
                    : holidayPlan
                if let displayedPlan { CalendarHolidayPlanView(plan: displayedPlan) }
            }
            if model.settings.calendarFeatures.contains(.holidays), !CalendarEngine.hasHolidayData(year: month.year) {
                Text(tr("该年份暂无中国法定假日与调休数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8 + DS.Space.s3)
        .padding(.bottom, 8 + DS.Space.s1)
    }

    private var agendaQuery: CalendarAgendaQuery {
        let calendar = CalendarEngine.gregorian()
        let start = calendar.startOfDay(for: days.first?.date ?? referenceDate ?? Date())
        let last = calendar.startOfDay(for: days.last?.date ?? start)
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        let settings = model.settings
        return .init(start: start, end: end,
                     events: settings.calendarPreferences.showEvents, reminders: settings.calendarPreferences.showReminders,
                     eventIDs: settings.calendarEventSourceIDs, reminderIDs: settings.calendarReminderSourceIDs,
                     revision: model.calendarAgenda.revision, timeZone: .current)
    }

    private func header(today: CalendarDay?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar").foregroundStyle(Color.accentColor)
            TextField(tr("年份"), text: $yearInput)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 62)
                .focused($yearFocused)
                .onSubmit(commitYearInput)
                .onChange(of: yearFocused) { _, focused in
                    if !focused { commitYearInput() }
                }
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
        return VStack(spacing: sizing.cellHeight < 50 ? 6 : 7) {
            HStack(spacing: 4) {
                ForEach(0..<7) { offset in
                    let weekday = (firstWeekday - 1 + offset) % 7 + 1
                    Text(weekdayName(weekday))
                        .font(.system(size: sizing.cellHeight < 50 ? 11 : 12, weight: .medium))
                        .foregroundStyle(weekday == 1 || weekday == 7 ? Color.red : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, sizing.cellHeight < 50 ? 2 : 3)
            // 月历固定最多 42 格，无需懒布局的高度估算与反复放置。
            VStack(spacing: sizing.cellHeight < 50 ? 3 : 4) {
                ForEach(0..<6) { row in
                    HStack(spacing: 4) {
                        ForEach(days.dropFirst(row * 7).prefix(7)) { day in
                            CalendarDayCell(day: day, features: features, isCurrentMonth: day.month == month.month,
                                            isToday: day.id == today?.id, isSelected: day.id == selected?.id,
                                            preferences: model.settings.calendarPreferences, sizing: sizing,
                                            hasAgenda: model.calendarAgenda.markedDays.contains(CalendarEngine.gregorian().startOfDay(for: day.date))) {
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
        }
    }

    private func detailHeader(today: CalendarDay?) -> some View {
        HStack {
            Button {
                // 单日详情是临时查看；返回默认月历时不留下历史日期的实心选中态。
                if let today { goToToday(today) }
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
        guard !isSnapshot else { return }
        guard showsDayDetails, let selected else {
            almanac = nil
            return
        }
        guard almanac?.id != selected.id else { return }
        almanac = CalendarEngine.almanac(for: selected)
    }

    private func refreshHolidayPlan(at date: Date) {
        guard !isSnapshot else { return }
        guard model.settings.calendarFeatures.contains(.holidays), model.settings.calendarPreferences.showHolidayOverview else {
            holidayPlan = nil
            return
        }
        holidayPlan = CalendarEngine.holidayPlan(from: date, displayedYear: month.year)
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

    private func commitYearInput() {
        if let year = Int(yearInput), CalendarMonth.years.contains(year) {
            month.year = year
        }
        yearInput = String(month.year)
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
    let preferences: CalendarPreferences
    let sizing: CalendarPopoverSizing
    let hasAgenda: Bool
    let action: () -> Void

    private var holiday: CalendarDay.Holiday? { features.contains(.holidays) ? day.holiday : nil }
    private var isRest: Bool { holiday.map { !$0.isWork } ?? day.isWeekend }
    private var foreground: Color { isSelected ? .white : isRest ? .red : DS.Palette.textPrimary }

    var body: some View {
        let showsLunar = features.contains(.lunar)
        let largeLunarText = showsLunar && preferences.largeLunarText
        let strongerLunarText = showsLunar && preferences.strongerLunarText
        Button(action: action) {
            VStack(spacing: sizing.cellHeight < 50 ? 2 : 3) {
                Text(String(day.day)).font(.system(size: sizing.dayFontSize,
                                                   weight: isToday ? .semibold : .regular, design: .rounded))
                Text(tr(day.subtitle(features: features)))
                    .font(.system(size: largeLunarText ? sizing.subtitleFontSize + 2 : sizing.subtitleFontSize,
                                  weight: strongerLunarText ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: sizing.cellHeight + (largeLunarText ? 8 : 0))
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
            .overlay(alignment: .bottom) {
                if hasAgenda {
                    Circle().fill(isSelected ? .white : Color.accentColor).frame(width: 4, height: 4).padding(.bottom, 3)
                }
            }
            .opacity(isCurrentMonth ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([day.id, features.contains(.lunar) ? day.lunarSummary : "", tr(day.subtitle(features: features)),
                             holiday.map { tr($0.isWork ? "调休上班" : "放假") } ?? "", isToday ? tr("今天") : "",
                             hasAgenda ? tr("有日程或提醒") : ""]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
