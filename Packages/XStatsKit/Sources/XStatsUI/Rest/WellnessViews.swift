// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Charts
import Localization
import SwiftUI

extension BreathingPattern {
    var title: String {
        switch self {
        case .gentle: tr("舒缓呼吸")
        case .box: tr("箱式呼吸")
        case .relax: "4–7–8"
        }
    }
}

extension BreathingPhase {
    var title: String {
        switch self {
        case .inhale: tr("吸气")
        case .hold: tr("屏息")
        case .exhale: tr("呼气")
        }
    }
}

extension WellnessActivityKind {
    var title: String {
        switch self {
        case .focus: tr("专注")
        case .rest: tr("休息")
        case .breathing: tr("呼吸练习")
        case .water: tr("饮水记录")
        }
    }
    var symbol: String {
        switch self {
        case .focus: "timer"
        case .rest: "eye"
        case .breathing: "wind"
        case .water: "drop"
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
        let preferences = model.settings.wellnessPreferences.normalized
        Card {
            HStack {
                Label(tr("健康提醒"), systemImage: "heart")
                    .dsFont(.sm, weight: .semibold)
                Spacer()
                if !wellness.pending.isEmpty {
                    Text(tr("待处理")).dsFont(.xs).foregroundStyle(DS.Palette.primary)
                }
            }
            VStack(spacing: DS.Space.s3) {
                reminderRow(.rest, enabled: preferences.breakEnabled, next: wellness.nextRestAt)
                HairlineDivider()
                reminderRow(.water, enabled: preferences.waterEnabled, next: wellness.nextWaterAt)
            }
            if !preferences.breakEnabled && !preferences.waterEnabled {
                Text(tr("在设置中开启提醒，未开始番茄钟时也能使用。"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.s2) {
                Button { wellness.recordWater() } label: { Label(tr("已喝水"), systemImage: "drop.badge.plus") }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                Button(tr("开始短休")) { wellness.startShortRest() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(wellness.activeExercise != nil)
                Button { wellness.startBreathing() } label: { Label(tr("呼吸练习"), systemImage: "wind") }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(wellness.activeExercise != nil)
                Spacer(minLength: 0)
            }
            if wellness.canContinueFocus && wellness.activeExercise == nil {
                Button(tr("继续专注")) { wellness.continueFocus() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
            }
            if let error = wellness.storageError {
                Text(error).dsFont(.xs).foregroundStyle(DS.Palette.error)
            }
        }
    }

    private func reminderRow(_ kind: HealthReminderKind, enabled: Bool, next: Date?) -> some View {
        let wellness = model.wellness
        return HStack(spacing: DS.Space.s3) {
            Image(systemName: kind == .rest ? "eye" : "drop")
                .foregroundStyle(kind == .rest ? Color.green : Color.blue)
                .frame(width: DS.Size.iconStandalone)
            VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                Text(tr(kind == .rest ? "休息提醒" : "喝水提醒")).dsFont(.sm, weight: .medium)
                Text(wellness.pending.contains(kind) ? tr(kind == .rest ? "看看远处，活动一下肩颈。" : "喝点水，按自己的需要记录。")
                     : enabled ? next.map { tr("下次提醒") + " · " + WellnessFormat.time($0) } ?? tr("已暂停") : tr("尚未开启"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s2)
            if kind == .water && wellness.lastWaterID != nil {
                Button(tr("撤销记录")) { wellness.undoWater() }
                    .buttonStyle(.plain).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
            if wellness.pending.contains(kind) {
                Button(tr("稍后")) { wellness.postpone(kind) }
                    .buttonStyle(.plain).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    .help(tr("稍后 10 分钟"))
            }
        }
    }
}

struct WellnessPreferencesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        SettingsGroup(caption: tr("健康提醒")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("休息提醒"), subtitle: tr("到期后轻量提示，临近番茄休息时合并。")) {
                    DSToggle(isOn: $settings.wellnessPreferences.breakEnabled, label: tr("休息提醒"))
                }
            }
            if settings.wellnessPreferences.breakEnabled {
                GroupRow {
                    SettingRow(title: tr("提醒间隔")) {
                        Picker(tr("提醒间隔"), selection: $settings.wellnessPreferences.breakIntervalMinutes) {
                            ForEach(WellnessPreferences.breakIntervals, id: \.self) { Text(tr("\(WellnessFormat.number($0)) 分钟")).tag($0) }
                        }.labelsHidden()
                    }
                }
            }
            GroupRow {
                SettingRow(title: tr("短休时长")) {
                    Picker(tr("短休时长"), selection: $settings.wellnessPreferences.breakSeconds) {
                        ForEach(WellnessPreferences.breakDurations, id: \.self) { Text(tr("\(WellnessFormat.number($0)) 秒")).tag($0) }
                    }.labelsHidden()
                }
            }
            GroupRow {
                SettingRow(title: tr("喝水提醒"), subtitle: tr("只在主动确认后记录，不自动计算饮水量。")) {
                    DSToggle(isOn: $settings.wellnessPreferences.waterEnabled, label: tr("喝水提醒"))
                }
            }
            if settings.wellnessPreferences.waterEnabled {
                GroupRow {
                    SettingRow(title: tr("提醒间隔")) {
                        Picker(tr("提醒间隔"), selection: $settings.wellnessPreferences.waterIntervalMinutes) {
                            ForEach(WellnessPreferences.waterIntervals, id: \.self) { Text(tr("\(WellnessFormat.number($0)) 分钟")).tag($0) }
                        }.labelsHidden()
                    }
                }
            }
            GroupRow {
                SettingRow(title: tr("每日记录目标"), subtitle: tr("按次数记录，目标可留空。")) {
                    Picker(tr("每日记录目标"), selection: $settings.wellnessPreferences.waterGoal) {
                        Text(tr("不设目标")).tag(Int?.none)
                        ForEach(Array(Set([4, 6, 8, 10, 12] + [settings.wellnessPreferences.waterGoal].compactMap { $0 })).sorted(), id: \.self) { Text(tr("\(WellnessFormat.number($0)) 次")).tag(Int?.some($0)) }
                    }.labelsHidden()
                }
            }
            GroupRow {
                SettingRow(title: tr("呼吸节奏"), subtitle: tr("舒缓模式不屏息，按舒适的节奏练习。")) {
                    Picker(tr("呼吸节奏"), selection: $settings.wellnessPreferences.breathingPattern) {
                        ForEach(BreathingPattern.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
            }
            GroupRow {
                SettingRow(title: tr("练习时长")) {
                    Picker(tr("练习时长"), selection: $settings.wellnessPreferences.breathingMinutes) {
                        ForEach(WellnessPreferences.breathingDurations, id: \.self) { Text(tr("\(WellnessFormat.number($0)) 分钟")).tag($0) }
                    }.labelsHidden()
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
                metric(tr("其中呼吸练习"), value: WellnessFormat.duration(today?.breathingSeconds ?? 0), symbol: "wind")
                metric(tr("饮水记录"), value: tr("\(WellnessFormat.number(today?.waterCount ?? 0)) 次"), symbol: "drop")
            }
            Text(tr("已记录 \(WellnessFormat.number(today?.focusCount ?? 0)) 轮"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            if let goal = model.settings.wellnessPreferences.waterGoal {
                HStack {
                    Text(tr("每日记录目标")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    Spacer()
                    Text("\(WellnessFormat.number(today?.waterCount ?? 0)) / \(WellnessFormat.number(goal))").dsFont(.xs).monospacedDigit()
                }
            }
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
            HStack {
                Text(tr("呼吸练习") + " · " + WellnessFormat.duration(wellness.summary.days.reduce(0) { $0 + $1.breathingSeconds }))
                Spacer()
                Text(tr("饮水记录") + " · " + tr("\(WellnessFormat.number(wellness.summary.days.reduce(0) { $0 + $1.waterCount })) 次"))
            }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
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
                            Text(activity.kind == .water ? tr("\(WellnessFormat.number(1)) 次") : WellnessFormat.duration(activity.duration))
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
        .confirmationDialog(tr("清除健康记录？"), isPresented: $confirmsClear, titleVisibility: .visible) {
            Button(tr("清除记录"), role: .destructive) { wellness.clearHistory() }
            Button(tr("取消"), role: .cancel) {}
        } message: { Text(tr("将删除本机健康活动记录，番茄配置和已有完成轮数保留。")) }
    }
}

/// 形变只用于呼吸节奏的状态指示；按单调时钟采样，暂停/恢复保持当前大小。
struct WellnessExerciseView: View {
    let wellness: WellnessController
    var reducedMotionPreview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        VStack(spacing: DS.Space.s6) {
            Text(tr(wellness.activeExercise == .breathing ? "呼吸练习" : "让眼睛休息一下"))
                .font(.system(size: 28, weight: .medium, design: .rounded))
            WellnessBreathingCircle(reading: wellness.breathingReading,
                                    running: wellness.activeExercise == .breathing && wellness.isExerciseRunning && !snapshot,
                                    reduceMotion: reduceMotion || reducedMotionPreview)
                .frame(width: 210, height: 210).accessibilityHidden(true)
            VStack(spacing: DS.Space.s2) {
                if wellness.activeExercise == .breathing {
                    Text(wellness.isExerciseRunning ? wellness.breathingReading?.phase.title ?? tr("吸气") : tr("已暂停"))
                        .dsFont(.lg, weight: .medium)
                }
                Text(WellnessFormat.timer(wellness.exerciseSecondsRemaining))
                    .font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
            }
            Text(tr(wellness.activeExercise == .breathing ? "按舒适的节奏呼吸，无需用力。" : "看看远处，轻轻眨眼，放松肩颈"))
                .dsFont(.sm).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s3) {
                if wellness.activeExercise == .breathing {
                    Button(tr(wellness.isExerciseRunning ? "暂停" : "继续")) { wellness.toggleBreathingPause() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
                Button(tr("结束练习")) { wellness.finishExercise(completed: false) }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
            }
            Text(tr("按 Esc 随时返回")).dsFont(.xs).foregroundStyle(.secondary)
        }
        .padding(DS.Space.s6).frame(maxWidth: 560)
        .appLanguageEnvironment()
    }
}
