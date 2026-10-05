// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.
import Localization
import SwiftUI

/// 可选模块的统一入口；沿用原有偏好绑定，关闭后保留配置与重新启用入口。
struct FeatureSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        SettingsGroup {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("进程"),
                           subtitle: tr("查看全部进程、搜索排序与结束进程，按需开启。"),
                           icon: "list.bullet.rectangle") {
                    DSToggle(isOn: $settings.processesEnabled, label: tr("进程"))
                }
            }
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("番茄钟与护眼休息"),
                           subtitle: tr("专注计时、每日目标与多屏休息幕布。"),
                           icon: "eye") {
                    HStack(spacing: DS.Space.s2) {
                        if settings.restEnabled { RestOptionsButton() }
                        DSToggle(isOn: $settings.restEnabled, label: tr("番茄钟与护眼休息"))
                    }
                }
            }
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("AI 用量"),
                           subtitle: tr("查看 Codex / Claude 的 Token 用量与订阅额度。"),
                           icon: "sparkles") {
                    DSToggle(isOn: $settings.aiUsageEnabled, label: tr("AI 用量"))
                }
            }
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("音频"), subtitle: tr("系统音量、音频设备与应用音量"), icon: "speaker.wave.2") {
                    DSToggle(isOn: $settings.audioEnabled, label: tr("音频"))
                }
            }
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("清理"),
                           subtitle: tr("按需扫描缓存、日志与项目产物，清理前逐项确认。"),
                           icon: "eraser") {
                    DSToggle(isOn: $settings.cleanerEnabled, label: tr("清理"))
                }
            }
            GroupRow {
                SettingRow(title: tr("菜单栏日历"),
                           subtitle: tr("独立显示日期，点击打开月历；不受指标合并布局影响"),
                           icon: "calendar") {
                    HStack(spacing: DS.Space.s2) {
                        if settings.calendarEnabled { CalendarOptionsButton() }
                        DSToggle(isOn: $settings.calendarEnabled, label: tr("菜单栏日历"))
                    }
                }
            }
        }
    }
}
