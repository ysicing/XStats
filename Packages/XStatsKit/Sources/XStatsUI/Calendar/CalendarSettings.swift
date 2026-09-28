// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import EventKit
import Localization
import SwiftUI

struct CalendarSettings: View {
    var body: some View {
        SettingsGroup(caption: tr("日历")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("菜单栏日历"), subtitle: tr("独立显示日期，点击打开月历；不受指标合并布局影响"), icon: "calendar") {
                    CalendarOptionsButton()
                }
            }
        }
    }
}

struct CalendarOptionsButton: View {
    @State private var isPresented = false

    var body: some View {
        Button(tr("设置")) { isPresented = true }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                CalendarOptionsPopover()
            }
    }
}

struct CalendarOptionsPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        @Bindable var settings = model.settings
        PageScroll {
            VStack(spacing: DS.Space.s4) {
                presentationOptions
                SettingsGroup(caption: tr("日历")) {
                    GroupRow(showsDivider: false) {
                        SettingRow(title: tr("每周开始于")) {
                            Picker(tr("每周开始于"), selection: $settings.calendarFirstWeekday) {
                                Text(tr("星期一")).tag(2)
                                Text(tr("星期日")).tag(1)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    ForEach(CalendarFeature.allCases) { feature in
                        GroupRow {
                            SettingRow(title: feature.title, subtitle: feature == .ganzhi ? tr("控制月历格中的日干支；黄历详情始终显示年月日干支") : nil) {
                                DSToggle(isOn: Binding(get: { settings.calendarFeatures.contains(feature) }, set: { enabled in
                                    if enabled { settings.calendarFeatures.insert(feature) }
                                    else { settings.calendarFeatures.remove(feature) }
                                }), label: feature.title)
                            }
                        }
                    }
                    GroupRow {
                        Text(tr("公历始终显示。藏历与回历显示在日期详情中；梅雨天按传统历法推算，并非天气预报。"))
                            .dsFont(.xs)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    GroupRow {
                        SettingRow(title: tr("放大农历文字")) {
                            DSToggle(isOn: $settings.calendarPreferences.largeLunarText, label: tr("放大农历文字"))
                        }
                    }
                    GroupRow {
                        SettingRow(title: tr("增强农历对比度")) {
                            DSToggle(isOn: $settings.calendarPreferences.strongerLunarText, label: tr("增强农历对比度"))
                        }
                    }
                    GroupRow {
                        SettingRow(title: tr("假期倒计时与请假建议")) {
                            DSToggle(isOn: $settings.calendarPreferences.showHolidayOverview, label: tr("假期倒计时与请假建议"))
                        }
                    }
                }
                agendaOptions
            }
            .padding(.vertical, DS.Space.s4)
        }
        .frame(width: 460)
        .frame(height: isSnapshot ? nil : 560)
        .fixedSize(horizontal: false, vertical: isSnapshot)
        .background(DS.Palette.background)
        .appLanguageEnvironment()
        .task(id: [settings.calendarPreferences.showEvents, settings.calendarPreferences.showReminders]) {
            guard !isSnapshot else { return }
            await model.calendarAgenda.refreshSources(events: settings.calendarPreferences.showEvents,
                                                      reminders: settings.calendarPreferences.showReminders)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !isSnapshot else { return }
            Task { await model.calendarAgenda.refreshSources(events: settings.calendarPreferences.showEvents,
                                                            reminders: settings.calendarPreferences.showReminders) }
        }
    }

    private var presentationOptions: some View {
        @Bindable var settings = model.settings
        return SettingsGroup(caption: tr("菜单栏")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("显示方式")) {
                    Picker(tr("显示方式"), selection: $settings.calendarPreferences.display) {
                        ForEach(CalendarPreferences.Display.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
            if settings.calendarPreferences.display == .custom {
                GroupRow {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("yyyy-MM-dd", text: Binding(get: { settings.calendarPreferences.dateFormat },
                                                              set: { settings.calendarPreferences.dateFormat = String($0.prefix(64)) }))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(tr("日期格式"))
                        Text(tr("年：yyyy 或 yy；月：MM 或 M；日：dd 或 d。分隔符可自行填写。"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(tr("例如 yyyy-MM-dd、M月d日、dd/MM；年份可省略。"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !settings.calendarPreferences.isDateFormatValid {
                            Text(tr("请包含月份 M 和日期 d；年份使用 y。格式无效时暂以月/日显示。"))
                                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            GroupRow {
                let preview = settings.calendarPreferences.title(at: Date(), locale: L10n.locale)
                HStack {
                    Text(tr("预览")).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "calendar")
                    Text(preview).font(.system(size: 12)).monospacedDigit().lineLimit(1)
                }
            }
            GroupRow {
                SettingRow(title: tr("悬停展开日历")) {
                    DSToggle(isOn: $settings.calendarPreferences.openOnHover, label: tr("悬停展开日历"))
                }
            }
            GroupRow {
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack { recoveryButtons }.fixedSize()
                        VStack(alignment: .leading, spacing: 8) { recoveryButtons }.fixedSize()
                    }
                    Text(tr("按住 ⌘ 拖动菜单栏图标可调整位置。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var recoveryButtons: some View {
        Button(tr("打开日历")) { model.openCalendar() }
        Button(tr("重新显示入口")) { model.restoreCalendarEntry() }
    }

    private var agendaOptions: some View {
        @Bindable var settings = model.settings
        return SettingsGroup(caption: tr("日程与提醒事项")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("显示系统日程")) {
                    DSToggle(isOn: $settings.calendarPreferences.showEvents, label: tr("显示系统日程"))
                }
            }
            if settings.calendarPreferences.showEvents {
                GroupRow { agendaAccess(reminders: false) }
            }
            GroupRow {
                SettingRow(title: tr("显示到期提醒")) {
                    DSToggle(isOn: $settings.calendarPreferences.showReminders, label: tr("显示到期提醒"))
                }
            }
            if settings.calendarPreferences.showReminders {
                GroupRow { agendaAccess(reminders: true) }
            }
            GroupRow {
                Text(tr("仅在本机展示日程与到期提醒，不修改内容。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func agendaAccess(reminders: Bool) -> some View {
        let agenda = model.calendarAgenda
        let access = reminders ? agenda.remindersAccess : agenda.eventsAccess
        let sources = reminders ? agenda.reminderSources : agenda.eventSources
        if access == .fullAccess {
            DisclosureGroup(tr("选择列表")) {
                VStack(alignment: .leading, spacing: 8) {
                    if sources.isEmpty { Text(tr("暂无可用列表")).foregroundStyle(.secondary) }
                    ForEach(sources) { source in
                        Toggle(source.title, isOn: Binding(get: {
                            let ids = reminders ? model.settings.calendarReminderSourceIDs : model.settings.calendarEventSourceIDs
                            return ids?.contains(source.id) ?? true
                        }, set: { selected in
                            var ids = (reminders ? model.settings.calendarReminderSourceIDs : model.settings.calendarEventSourceIDs)
                                ?? Set(sources.map(\.id))
                            if selected { ids.insert(source.id) } else { ids.remove(source.id) }
                            if reminders { model.settings.calendarReminderSourceIDs = ids }
                            else { model.settings.calendarEventSourceIDs = ids }
                        }))
                        .toggleStyle(.checkbox)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(access == .notDetermined || access == .writeOnly ? "需要授权后才能显示" : "访问未获允许，请在系统设置中开启"))
                    .font(.caption).foregroundStyle(.secondary)
                if access == .notDetermined || access == .writeOnly {
                    Button(tr("允许访问")) { Task { await agenda.requestAccess(reminders: reminders) } }
                        .disabled(agenda.isRequesting)
                } else {
                    Button(tr("打开系统设置")) {
                        let destination = reminders ? "Privacy_Reminders" : "Privacy_Calendars"
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + destination) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                if agenda.failed { Text(tr("读取失败，请重试")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

}
