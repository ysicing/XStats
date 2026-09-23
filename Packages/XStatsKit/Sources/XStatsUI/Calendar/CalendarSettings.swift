// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct CalendarSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        SettingsGroup(caption: tr("日历")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("菜单栏日历"), subtitle: tr("独立显示日期，点击打开月历；不受指标合并布局影响"), icon: "calendar") {
                    DSToggle(isOn: $settings.calendarEnabled, label: tr("菜单栏日历"))
                }
            }
            if settings.calendarEnabled {
                GroupRow {
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
            }
        }
    }
}
