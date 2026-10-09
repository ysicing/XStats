// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Charts
import Localization
import SwiftUI

extension WellnessActivityKind {
    var title: String {
        switch self {
        case .focus: tr("专注")
        case .rest: tr("休息")
        }
    }
    var symbol: String {
        switch self {
        case .focus: "timer"
        case .rest: "eye"
        }
    }
}

enum WellnessFormat {
    static func timer(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded(.up)))
            .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)).locale(L10n.locale))
    }
    static func number(_ value: Int) -> String { value.formatted(.number.locale(L10n.locale)) }
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds > 0 && seconds < 60 { return tr("\(number(Int(seconds.rounded(.down)))) 秒") }
        return tr("\(number(Int(max(0, seconds) / 60))) 分钟")
    }
    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute().locale(L10n.locale)) }
}

struct WellnessHealthCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let wellness = model.wellness
        Card {
            HStack {
                Label(tr("护眼休息"), systemImage: "eye").dsFont(.sm, weight: .semibold)
                Spacer()
                Button(tr("开始护眼休息")) { wellness.startShortRest() }
                    .buttonStyle(DSButtonStyle(kind: .secondary)).disabled(wellness.isEyeRestActive)
            }
            Text(tr("看看远处，活动一下肩颈。"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            if wellness.pending.contains(.rest) {
                HStack {
                    Text(tr("待处理")).dsFont(.xs).foregroundStyle(DS.Palette.primary)
                    Spacer()
                    Button(tr("稍后")) { wellness.postpone(.rest) }
                        .buttonStyle(.plain).dsFont(.xs).help(tr("稍后 10 分钟"))
                }
            } else if model.settings.wellnessPreferences.breakEnabled {
                Text(wellness.nextRestAt.map { tr("下次提醒") + " · " + WellnessFormat.time($0) } ?? tr("已暂停"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
            if wellness.canContinueFocus && !wellness.isEyeRestActive {
                Button(tr("继续专注")) { wellness.continueFocus() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
            }
            if let error = wellness.storageError { Text(error).dsFont(.xs).foregroundStyle(DS.Palette.error) }
        }
    }
}

struct WellnessPreferencesSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        SettingsGroup(caption: tr("护眼休息")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("护眼休息时长"), subtitle: tr("看看远处，放松肩颈；与轮间休息分别设置。")) {
                    Picker(tr("护眼休息时长"), selection: $settings.wellnessPreferences.breakSeconds) {
                        ForEach(WellnessPreferences.breakDurations, id: \.self) { Text(WellnessFormat.duration(Double($0))).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                    .frame(width: 160, alignment: .trailing)
                }
            }
            GroupRow {
                SettingRow(title: tr("定时提醒"), subtitle: tr("临近轮间休息时合并提醒，避免重复打扰。")) {
                    DSToggle(isOn: $settings.wellnessPreferences.breakEnabled, label: tr("护眼提醒"))
                }
            }
            if settings.wellnessPreferences.breakEnabled {
                GroupRow {
                    SettingRow(title: tr("提醒间隔")) {
                        Picker(tr("提醒间隔"), selection: $settings.wellnessPreferences.breakIntervalMinutes) {
                            ForEach(WellnessPreferences.breakIntervals, id: \.self) { Text(tr("\(WellnessFormat.number($0)) 分钟")).tag($0) }
                        }.labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                    .frame(width: 160, alignment: .trailing)
                    }
                }
            }
        }
    }
}

struct WellnessTodayCard: View {
    @Environment(AppModel.self) private var model
    @State private var showsStatistics = false

    var body: some View {
        let today = model.wellness.summary.today
        Card {
            HStack {
                Label(tr("今日概览"), systemImage: "chart.bar")
                    .dsFont(.sm, weight: .semibold)
                Spacer()
                Button(tr("查看统计")) { showsStatistics = true }
                    .buttonStyle(.plain).dsFont(.xs).foregroundStyle(DS.Palette.primary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: DS.Space.s3) {
                metric(tr("专注"), value: WellnessFormat.duration(today?.focusSeconds ?? 0), symbol: "timer")
                metric(tr("休息"), value: WellnessFormat.duration(today?.restSeconds ?? 0), symbol: "eye")
            }
            Text(tr("已记录 \(WellnessFormat.number(today?.focusCount ?? 0)) 轮"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)

        }
        .sheet(isPresented: $showsStatistics) { WellnessStatisticsView(wellness: model.wellness) }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: symbol).foregroundStyle(DS.Palette.textSecondary)
                .frame(width: DS.Size.iconStandalone)
            VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                Text(title).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                Text(value).dsFont(.base, weight: .semibold).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }
}

struct WellnessStatisticsView: View {
    let wellness: WellnessController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack {
                Text(tr("活动统计")).dsFont(.lg, weight: .semibold)
                Spacer()
                MiniIconButton(systemName: "xmark", help: tr("关闭")) { dismiss() }
            }
            Text(tr("最近 7 天")).dsFont(.sm, weight: .medium)
            Chart(wellness.summary.days) { day in
                BarMark(x: .value(tr("日期"), day.date, unit: .day), y: .value(tr("分钟"), day.focusSeconds / 60))
                    .foregroundStyle(by: .value(tr("活动"), tr("专注")))
                BarMark(x: .value(tr("日期"), day.date, unit: .day), y: .value(tr("分钟"), day.restSeconds / 60))
                    .foregroundStyle(by: .value(tr("活动"), tr("休息")))
            }
            .chartForegroundStyleScale([tr("专注"): Color.blue, tr("休息"): Color.green])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(date.formatted(.dateTime.weekday(.abbreviated).locale(L10n.locale))) }
                    }
                }
            }
            .frame(height: 150)
            Text(tr("今日时间线")).dsFont(.sm, weight: .medium)
            ScrollView {
                LazyVStack(spacing: DS.Space.s3) {
                    if wellness.summary.todayActivities.isEmpty {
                        Text(tr("今天还没有活动记录。"))
                            .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary).padding(.vertical, DS.Space.s6)
                    }
                    ForEach(Array(wellness.summary.todayActivities.suffix(100).reversed())) { activity in
                        HStack(spacing: DS.Space.s3) {
                            Image(systemName: activity.kind.symbol).frame(width: DS.Size.iconStandalone)
                                .foregroundStyle(DS.Palette.textSecondary)
                            VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                                Text(activity.kind.title).dsFont(.sm)
                                Text(WellnessFormat.time(activity.startedAt)).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                            }
                            Spacer()
                            Text(WellnessFormat.duration(activity.duration))
                                .dsFont(.sm).monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 210)
            HStack {
                Text(tr("仅保存在这台 Mac，保留 90 天。"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button(tr("清除记录"), role: .destructive) { confirmsClear = true }
                    .buttonStyle(.plain).dsFont(.xs)
            }
        }
        .padding(DS.Space.s6).frame(width: 560)
        .appLanguageEnvironment()
        .confirmationDialog(tr("清除活动记录？"), isPresented: $confirmsClear, titleVisibility: .visible) {
            Button(tr("清除记录"), role: .destructive) { wellness.clearHistory() }
            Button(tr("取消"), role: .cancel) {}
        } message: { Text(tr("将删除本机专注与休息记录，计时配置和已有完成轮数保留。")) }
    }
}

/// 护眼幕布复用轮间休息的倒计时视觉，保持独立窗口中的语言与控件一致。
struct WellnessEyeRestView: View {
    let wellness: WellnessController
    var body: some View {
        let language = wellness.settings.language.resolved
        VStack(spacing: 22) {
            RestCountdownRing(title: tr("护眼休息"), secondsRemaining: wellness.eyeRestSecondsRemaining,
                              duration: wellness.eyeRestDuration)
            Text(tr("让眼睛休息一下")).font(.system(size: 34, weight: .medium, design: .rounded))
            Text(tr("看看远处，轻轻眨眼，放松肩颈"))
                .font(.system(size: 16)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(tr("结束")) { wellness.finishEyeRest(completed: false) }
                .buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 22).padding(.vertical, 12).background(.regularMaterial, in: Capsule())
            Text(tr("按 Esc 随时返回")).dsFont(.xs).foregroundStyle(.secondary)
        }
        .padding(DS.Space.s6).frame(maxWidth: 560)
        .environment(\.locale, L10n.locale(for: language))
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}
