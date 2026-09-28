// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import EventKit
import Localization
import SwiftUI

struct CalendarAgendaView: View {
    @Environment(AppModel.self) private var model
    let day: CalendarDay

    private var items: [CalendarAgendaItem] {
        model.calendarAgenda.items.filter { $0.occurs(on: day.date, calendar: CalendarEngine.gregorian()) }
    }

    var body: some View {
        let agenda = model.calendarAgenda
        let preferences = model.settings.calendarPreferences
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tr("日程与提醒事项"), systemImage: "calendar.badge.clock").font(.subheadline.weight(.medium))
                Spacer()
                Text(day.date.formatted(.dateTime.month().day().locale(L10n.locale))).font(.caption).foregroundStyle(.secondary)
            }
            if preferences.showEvents && agenda.eventsAccess != .fullAccess {
                accessNotice(tr("日程尚未授权"))
            }
            if preferences.showReminders && agenda.remindersAccess != .fullAccess {
                accessNotice(tr("提醒事项尚未授权"))
            }
            if agenda.isLoading {
                ProgressView().controlSize(.small)
            } else if agenda.failed {
                Button(tr("读取失败，请重试")) { agenda.revision += 1 }.buttonStyle(.borderless)
            } else if !items.isEmpty {
                ForEach(items.prefix(40)) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isReminder ? "checklist" : "calendar")
                            .foregroundStyle(item.isReminder ? .orange : Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title.isEmpty ? tr("无标题") : item.title).font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.source).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.isAllDay ? tr("全天") : item.start.formatted(.dateTime.hour().minute().locale(L10n.locale)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if items.count > 40 {
                    Text(tr("更多内容请在系统日历或提醒事项中查看")).font(.caption).foregroundStyle(.secondary)
                }
            } else if (preferences.showEvents && agenda.eventsAccess == .fullAccess) ||
                        (preferences.showReminders && agenda.remindersAccess == .fullAccess) {
                let noEvents = !preferences.showEvents || model.settings.calendarEventSourceIDs?.isEmpty == true
                let noReminders = !preferences.showReminders || model.settings.calendarReminderSourceIDs?.isEmpty == true
                Text(tr(noEvents && noReminders ? "尚未选择任何列表" : "这一天没有日程或到期提醒"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(DS.Palette.textSecondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func accessNotice(_ title: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(tr("日历设置…")) { model.openMainWindow(.settingsMenuBar) }.buttonStyle(.borderless)
        }
    }
}

struct CalendarHolidayPlanView: View {
    let plan: CalendarHolidayPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(tr(plan.name), systemImage: "sun.max").font(.subheadline.weight(.medium))
                Spacer()
                Text(plan.daysUntil == 0 ? tr("假期中") : tr("还有 \(number(plan.daysUntil)) 天"))
                    .font(.subheadline).foregroundStyle(Color.accentColor)
            }
            Text(tr("\(range(plan.start, plan.end)) · 连休 \(number(plan.totalDays)) 天"))
                .font(.caption).foregroundStyle(.secondary)
            if !plan.leaveOptions.isEmpty {
                DisclosureGroup(tr("请假建议")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(plan.leaveOptions) { option in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tr("请 \(number(option.leaveDates.count)) 天，连休 \(number(option.totalDays)) 天"))
                                    .font(.subheadline)
                                Text(range(option.start, option.end)).font(.caption).foregroundStyle(.secondary)
                                let dates = option.leaveDates.map { $0.formatted(.dateTime.month().day().locale(L10n.locale)) }
                                Text(tr("请假日期：\(dates.formatted(.list(type: .and).locale(L10n.locale)))"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(tr("按双休及已公布的中国调休安排计算，实际请假以单位批准为准。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func number(_ value: Int) -> String { value.formatted(.number.locale(L10n.locale)) }

    private func range(_ start: Date, _ end: Date) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = CalendarEngine.gregorian()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: end)
    }
}
