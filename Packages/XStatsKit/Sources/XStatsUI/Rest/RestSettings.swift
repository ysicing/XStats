// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

public enum RestHUDStyle: String, CaseIterable, Identifiable, Sendable {
    case countdown, ring, hourglass

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .countdown: tr("数字倒计时")
        case .ring: tr("进度圆环")
        case .hourglass: tr("沙漏")
        }
    }

    var symbol: String {
        switch self {
        case .countdown: "numbersign"
        case .ring: "circle.dotted.circle"
        case .hourglass: "hourglass"
        }
    }

    var next: Self {
        switch self {
        case .countdown: .ring
        case .ring: .hourglass
        case .hourglass: .countdown
        }
    }
}

/// 与菜单栏日历一致：通用页只保留模块开关，详细选项由独立弹出层承载。
struct RestOptionsButton: View {
    @State private var isPresented = false

    var body: some View {
        Button(tr("设置")) { isPresented = true }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                RestOptionsPopover()
            }
    }
}

private struct RestOptionsPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        ScrollView {
            SettingsGroup(caption: tr("番茄钟")) {
                GroupRow(showsDivider: false) {
                    SettingRow(title: tr("工作时长（分钟）")) {
                        Picker(tr("工作时长（分钟）"), selection: $settings.restWorkMinutes) {
                            ForEach(AppSettings.restWorkOptions, id: \.self) { minutes in
                                Text(tr("\(minutes) 分钟")).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                }
                GroupRow {
                    SettingRow(title: tr("休息时长（分钟）")) {
                        Picker(tr("休息时长（分钟）"), selection: $settings.restBreakMinutes) {
                            ForEach(AppSettings.restBreakOptions, id: \.self) { minutes in
                                Text(tr("\(minutes) 分钟")).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                }
                GroupRow {
                    SettingRow(title: tr("长休时长（分钟）"), subtitle: tr("每完成 4 轮专注后进入长休")) {
                        Picker(tr("长休时长（分钟）"), selection: $settings.restLongBreakMinutes) {
                            ForEach(AppSettings.restLongBreakOptions, id: \.self) { minutes in
                                Text(tr("\(minutes) 分钟")).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                }
                GroupRow {
                    SettingRow(title: tr("每日目标")) {
                        Picker(tr("每日目标"), selection: $settings.restDailyGoal) {
                            ForEach(AppSettings.restDailyGoalOptions, id: \.self) { count in
                                Text(tr("\(count) 轮")).tag(count)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                }
                GroupRow {
                    SettingRow(title: tr("休息声音"), subtitle: tr("仅在休息时本地实时合成")) {
                        Picker(tr("休息声音"), selection: $settings.restSound) {
                            ForEach(RestSound.allCases) { sound in
                                Text(sound.title).tag(sound)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                }
                GroupRow {
                    SettingRow(title: tr("迷你 HUD 样式")) {
                        Picker(tr("迷你 HUD 样式"), selection: $settings.restHUDStyle) {
                            ForEach(RestHUDStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                }
            }
            .padding(DS.Space.s4)
        }
        .frame(width: 480, height: 410)
        .appLanguageEnvironment()
    }
}
