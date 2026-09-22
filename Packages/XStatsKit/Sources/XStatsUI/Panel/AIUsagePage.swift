// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Localization
import SwiftUI

struct AIUsagePage: View {
    var body: some View { PageScroll { LocalUsageContent(compact: false) } }
}
struct AIUsagePopover: View {
    var body: some View { LocalUsageContent(compact: true) }
}

private struct LocalUsageContent: View {
    let compact: Bool
    @Environment(AppModel.self) private var model
    @State private var selectedModel = ""
    @State private var source = "all"
    @State private var settingsOpen = false
    @State private var activityMode = UsageActivityMode.daily

    private var provider: AIProviderID? {
        AIProviderID(rawValue: source).flatMap { model.settings.aiUsageSources.contains($0) ? $0 : nil }
    }
    private var sourceOptions: [(String, String)] {
        [("all", tr("全部"))] + AIProviderID.allCases.filter { model.settings.aiUsageSources.contains($0) }
            .map { ($0.rawValue, $0 == .codex ? "Codex" : "Claude") }
    }
    private var sourceTitle: String {
        if let provider { return provider == .codex ? "Codex" : "Claude Code" }
        return AIProviderID.allCases.filter { model.settings.aiUsageSources.contains($0) }
            .map { $0 == .codex ? "Codex" : "Claude Code" }.joined(separator: " + ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? DS.Space.s3 : DS.Space.s4) {
            toolbar
            if !model.settings.aiUsageEnabled {
                Card {
                    Label(tr("AI 使用统计"), systemImage: "chart.bar").dsFont(.base, weight: .semibold)
                    Text(tr("只读本机 Codex / Claude Code 会话日志，按模型统计 Token；不读取登录凭据，不查询订阅额度。"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(tr("启用使用统计")) { model.settings.aiUsageEnabled = true }
                        .buttonStyle(DSButtonStyle(kind: .primary))
                }
            } else if model.settings.aiUsageSources.isEmpty {
                Card {
                    Text(tr("数据来源") + " · " + tr("尚未启用")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
                    Button(tr("设置")) { settingsOpen = true }.buttonStyle(DSButtonStyle(kind: .secondary))
                }
            } else if let report = model.aiUsage.localReport(for: provider) {
                let rows = report.summary(mode: activityMode, model: selectedModel.isEmpty ? nil : selectedModel)
                let activityRows = report.selected(days: 365, model: selectedModel.isEmpty ? nil : selectedModel)
                let total = LocalUsageReport.total(rows)
                UsageSummary(total: total, compact: compact,
                             title: selectedModel.isEmpty ? sourceTitle : selectedModel)
                UsageHeatmap(rows: activityRows, compact: compact, mode: $activityMode)
                modelRanking(report: report, rows: rows, total: total)
                status(report)
            } else {
                VStack(spacing: DS.Space.s3) {
                    if model.aiUsage.isRefreshing { ProgressView().controlSize(.small) }
                    Image(systemName: "chart.bar.xaxis").font(.system(size: DS.TextSize.xl.rawValue))
                        .foregroundStyle(DS.Palette.textTertiary)
                    Text(tr(model.aiUsage.isRefreshing ? "正在读取会话日志…" : "暂无本机用量数据"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, DS.Space.s12)
            }
        }
        .onChange(of: model.settings.aiUsageSources) { _, sources in
            if let id = AIProviderID(rawValue: source), !sources.contains(id) { source = "all" }
            selectedModel = ""
        }
    }

    private var toolbar: some View {
        VStack(spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                UsageChoices(selection: $source, options: sourceOptions,
                             label: tr("数据来源"))
                    .frame(maxWidth: compact ? .infinity : 260)
                    .onChange(of: source) { _, _ in selectedModel = "" }
                if !compact {
                    Spacer(minLength: DS.Space.s4)
                }
                refreshButton
                MiniIconButton(systemName: "gearshape", help: tr("设置")) { settingsOpen.toggle() }
                    .popover(isPresented: $settingsOpen) { UsageSettings().padding(DS.Space.s4).frame(width: 360) }
            }
        }
    }

    private var refreshButton: some View {
        ZStack {
            MiniIconButton(systemName: "arrow.clockwise", help: tr("立即刷新")) {
                Task { await model.aiUsage.refresh() }
            }
            .opacity(model.aiUsage.isRefreshing ? 0 : 1)
            .disabled(!model.settings.aiUsageEnabled || model.settings.aiUsageSources.isEmpty || model.aiUsage.isRefreshing)
            if model.aiUsage.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel(tr("正在刷新")) }
        }.frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
    }

    private func modelRanking(report: LocalUsageReport, rows: [ModelTokenUsage], total: ModelTokenUsage) -> some View {
        let models = LocalUsageReport.models(rows)
        return Card(spacing: DS.Space.s4) {
            HStack {
                Text(tr("模型排行")).dsFont(.sm, weight: .semibold)
                Spacer()
                Picker(tr("模型"), selection: $selectedModel) {
                    Text(tr("全部模型")).tag("")
                    ForEach(Array(Set(report.rows.map(\.model))).sorted(), id: \.self) { name in
                        Text(verbatim: name).tag(name)
                    }
                }
                .labelsHidden().controlSize(.small)
                .frame(maxWidth: compact ? 150 : 220, alignment: .trailing)
                .accessibilityLabel(tr("模型"))
            }
            if models.isEmpty {
                Text(tr("所选时间范围没有用量记录")).dsFont(.xs)
                    .foregroundStyle(DS.Palette.textSecondary).padding(.vertical, DS.Space.s4)
            }
            ForEach(models) { item in
                UsageModelRow(item: item, total: total.total, compact: compact)
                if item.id != models.last?.id { HairlineDivider() }
            }
        }
    }

    private func status(_ report: LocalUsageReport) -> some View {
        let state = model.aiUsage.localState(for: provider)
        return VStack(alignment: .leading, spacing: DS.Space.s1) {
            if report.unreadableFiles > 0 {
                Label(tr("部分会话日志无法读取，统计可能不完整"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DS.Palette.warning)
            }
            if state.stale {
                Label(tr("读取失败，显示上次统计结果"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DS.Palette.warning)
            }
            HStack {
                Spacer()
                if let updated = state.updated {
                    Text(tr("上次检查：\(updated.formatted(date: .omitted, time: .shortened))"))
                }
            }.foregroundStyle(DS.Palette.textTertiary)
        }.dsFont(.xs)
    }
}

/// 鼠标选择只对选中底色作短暂淡入；键盘选择即时响应，不动画数据、图表或布局。
private struct UsageChoices<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    let label: String
    @State private var pointerSelection = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Space.s1 / 2) {
            ForEach(options, id: \.0) { value, title in
                Button {
                    pointerSelection = true
                    selection = value
                } label: {
                    Text(title).dsFont(.xs, weight: selection == value ? .semibold : .medium)
                        .foregroundStyle(selection == value ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.s2)
                        .background {
                            RoundedRectangle(cornerRadius: DS.Radius.md)
                                .fill(DS.Palette.elevated)
                                .opacity(selection == value ? 1 : 0)
                                .animation(pointerSelection ? (reduceMotion ? DS.Motion.quick : DS.Motion.usageSelection) : nil,
                                           value: selection)
                        }
                }
                .buttonStyle(UsagePressStyle())
                .accessibilityLabel(title)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
                .onKeyPress(.space) { selectWithKeyboard(value); return .handled }
                .onKeyPress(.return) { selectWithKeyboard(value); return .handled }
            }
        }
        .padding(DS.Space.s1 / 2)
        .background(DS.Palette.track, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func selectWithKeyboard(_ value: Value) {
        pointerSelection = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { selection = value }
    }
}

private struct UsagePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

enum UsageNumber {
    static func short(_ value: Int, locale: Locale = L10n.locale) -> String {
        let chinese = locale.language.languageCode?.identifier == "zh"
        let units: [(Int, String)] = chinese
            ? [(100_000_000, "亿"), (1_000_000, "百万"), (10_000, "万"), (1_000, "千")]
            : [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        guard let (divisor, rawUnit) = units.first(where: { value >= $0.0 }) else {
            return value.formatted(.number.locale(locale))
        }
        let unit = locale.language.script?.identifier == "Hant"
            ? rawUnit.replacingOccurrences(of: "亿", with: "億").replacingOccurrences(of: "万", with: "萬") : rawUnit
        let number = (Double(value) / Double(divisor)).formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        return number + (chinese ? " " : "") + unit
    }
}

private struct UsageSummary: View {
    let total: ModelTokenUsage
    let compact: Bool
    let title: String
    @State private var expanded = false

    var body: some View {
        Card(padding: DS.Space.s6, spacing: compact ? DS.Space.s3 : DS.Space.s6) {
            HStack {
                Text(title).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Text(UsageNumber.short(total.total))
                    .dsFont(.xxl, weight: .semibold)
                    .tracking(-0.6).monospacedDigit()
                    .help(total.total.formatted())
                    .accessibilityLabel(total.total.formatted() + " Tokens")
                Text("Tokens").dsFont(.sm).foregroundStyle(DS.Palette.textTertiary)
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: compact ? 2 : 4),
                      alignment: .leading, spacing: DS.Space.s3) {
                UsageMetric(title: tr("输入 Token"), value: UsageNumber.short(total.input), exact: total.input.formatted())
                UsageMetric(title: tr("输出 Token"), value: UsageNumber.short(total.output), exact: total.output.formatted())
                UsageMetric(title: tr("缓存命中率"), value: total.input > 0
                    ? (Double(total.cached) / Double(total.input)).formatted(.percent.precision(.fractionLength(1))) : "—")
                UsageMetric(title: tr("用量记录"), value: total.records.formatted())
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: DS.Space.s2) {
                    InfoRow(label: tr("缓存 Token"), text: total.cached.formatted())
                    InfoRow(label: tr("缓存创建 Token"), text: total.cacheCreated.formatted())
                    Text(tr("缓存 Token 已包含在输入中，推理 Token 已包含在输出中。"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, DS.Space.s2)
            } label: {
                Text(tr("缓存 Token")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }
}

private struct UsageMetric: View {
    let title: String
    let value: String
    var exact: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(title).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            Text(value).dsFont(.base, weight: .medium).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .help(exact.isEmpty ? value : exact)
                .accessibilityLabel(exact.isEmpty ? value : exact)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageModelRow: View {
    let item: ModelTokenUsage
    let total: Int
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: DS.Space.s2) {
                    Circle().fill(DS.Palette.primary).frame(width: DS.Space.s1, height: DS.Space.s1)
                    Text(verbatim: item.model).dsFont(.xs, weight: .medium).lineLimit(1).help(item.model)
                }
                Spacer(minLength: DS.Space.s2)
                Text(UsageNumber.short(item.total)).dsFont(.sm, weight: .semibold)
                    .monospacedDigit().fixedSize().help(item.total.formatted())
                    .accessibilityLabel(item.total.formatted() + " Tokens")
                Text((total > 0 ? Double(item.total) / Double(total) : 0).formatted(.percent.precision(.fractionLength(0))))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    .monospacedDigit().frame(width: DS.Space.s12, alignment: .trailing)
            }
            ProgressTrack(fraction: total > 0 ? Double(item.total) / Double(total) : 0,
                          color: DS.Palette.primary, height: DS.Space.s1 / 2, showsTrack: false)
                .accessibilityHidden(true)
            if !compact {
                HStack(spacing: DS.Space.s6) {
                    Text(tr("输入 Token") + "  " + UsageNumber.short(item.input))
                    Text(tr("输出 Token") + "  " + UsageNumber.short(item.output))
                    Spacer()
                    Text(tr("用量记录") + "  " + item.records.formatted())
                }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
            }
        }.padding(.vertical, DS.Space.s1)
    }
}

/// 活动图始终展示全年；模式绑定到父视图，同时切换摘要和排行的本日/本周/本月口径。
private struct UsageHeatmap: View {
    let rows: [ModelTokenUsage]
    let compact: Bool
    @Binding var mode: UsageActivityMode
    @State private var hovered: String?

    var body: some View {
        let activity = UsageActivity(rows: rows)
        let peak = activity.peak(for: mode)
        Card(spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Text(tr("Token 活动")).dsFont(.sm, weight: .semibold)
                Spacer(minLength: DS.Space.s2)
                UsageChoices(selection: $mode, options: [
                    (.daily, tr("每日")), (.weekly, tr("每周")), (.cumulative, tr("累计"))
                ], label: tr("Token 活动"))
                .frame(width: compact ? 175 : 200)
            }
            Text(hovered ?? " ")
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, DS.Space.s2)
                .padding(.vertical, DS.Space.s1 / 2)
                .background(hovered == nil ? Color.clear : DS.Palette.track, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: DS.Space.s6)
                .accessibilityHidden(hovered == nil)
            if compact {
                ScrollView(.horizontal) {
                    ActivityGrid(activity: activity, mode: mode, hovered: $hovered)
                        .frame(width: DS.Size.panelWidth - DS.Space.s8, height: gridHeight)
                }
                .defaultScrollAnchor(.trailing)
            } else {
                ActivityGrid(activity: activity, mode: mode, hovered: $hovered)
                    .frame(height: gridHeight)
            }
            HStack {
                if !compact {
                    Text(activity.start.formatted(.dateTime.year().month().day()) + " – " +
                         activity.end.formatted(.dateTime.month().day()))
                    Spacer()
                }
                Text("0")
                HStack(spacing: DS.Space.s1 / 2) {
                        ForEach(0..<5) { level in
                            RoundedRectangle(cornerRadius: DS.Space.s1 / 2)
                                .fill(level == 0 ? DS.Palette.track : DS.Palette.primary.opacity(mode == .daily
                                    ? Double(level) / 4 : UsageActivity.colorIntensity(value: level, peak: 4, mode: mode)))
                                .frame(width: DS.Space.s3, height: DS.Space.s3)
                        }
                }.accessibilityHidden(true)
                Text(UsageNumber.short(peak) + " Tokens").help(peak.formatted() + " Tokens")
            }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        }
        .onChange(of: mode) { _, _ in hovered = nil }
        .onChange(of: rows) { _, _ in hovered = nil }
    }

    private var gridHeight: CGFloat { 7 * DS.Space.s3 + 6 * (DS.Space.s1 / 2) + DS.Space.s6 }
}

private struct ActivityGrid: View {
    let activity: UsageActivity
    let mode: UsageActivityMode
    @Binding var hovered: String?

    var body: some View {
        GeometryReader { geometry in
            let gap = DS.Space.s1 / 2
            let columns = activity.weeks.count
            let side = min(DS.Space.s3, max(1, (geometry.size.width - CGFloat(columns - 1) * gap) / CGFloat(max(1, columns))))
            HStack(alignment: .top, spacing: gap) {
                ForEach(activity.weeks) { week in
                    ActivityWeek(week: week, activity: activity, mode: mode, side: side, hovered: $hovered)
                }
            }
        }
    }
}

private struct ActivityWeek: View {
    let week: UsageActivity.Week
    let activity: UsageActivity
    let mode: UsageActivityMode
    let side: CGFloat
    @Binding var hovered: String?

    private var weekLabel: String {
        let date = week.start.formatted(.dateTime.year().month().day())
        return mode == .weekly
            ? tr("\(date) 当周：\(UsageNumber.short(week.total)) Tokens")
            : tr("截至 \(date) 当周累计：\(UsageNumber.short(week.cumulative)) Tokens")
    }

    var body: some View {
        let peak = activity.peak(for: mode)
        let value = mode == .weekly ? week.total : week.cumulative
        let filled = UsageActivity.filledCells(value: value, peak: peak)
        let intensity = UsageActivity.colorIntensity(value: value, peak: peak, mode: mode)
        VStack(spacing: DS.Space.s1 / 2) {
            ForEach(0..<7, id: \.self) { row in
                if mode == .daily {
                    if let date = week.days[row] {
                        let count = activity.daily[date] ?? 0
                        let level = min(4, max(1, Int(ceil(Double(count) / Double(max(1, peak)) * 4))))
                        ActivityCell(side: side,
                            color: count == 0 ? DS.Palette.track : DS.Palette.primary.opacity(Double(level) / 4),
                            label: date.formatted(.dateTime.year().month().day()) + " · " + UsageNumber.short(count) + " Tokens",
                            hovered: $hovered)
                    } else {
                        Color.clear.frame(width: side, height: side).accessibilityHidden(true)
                    }
                } else {
                    ActivityCell(side: side, color: row >= 7 - filled ? DS.Palette.primary.opacity(intensity) : DS.Palette.track,
                                 label: weekLabel, hovered: $hovered)
                }
            }
            Color.clear.frame(width: side, height: DS.Space.s4)
                .overlay(alignment: .leading) {
                    if let month = week.days.compactMap({ $0 }).first(where: { Calendar.current.component(.day, from: $0) == 1 }) {
                        Text(month.formatted(.dateTime.month(.abbreviated)))
                            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).fixedSize()
                    }
                }
        }
    }
}

private struct ActivityCell: View {
    let side: CGFloat
    let color: Color
    let label: String
    @Binding var hovered: String?

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Space.s1 / 2)
            .fill(color).frame(width: side, height: side)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = label }
                else if hovered == label { hovered = nil }
            }
            .accessibilityLabel(label)
    }
}

private struct UsageSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text(tr("设置")).dsFont(.base, weight: .semibold)
            SettingRow(title: tr("AI 使用统计"), subtitle: nil) {
                DSToggle(isOn: $settings.aiUsageEnabled, label: tr("AI 使用统计"))
            }
            HairlineDivider()
            Text(tr("数据来源")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            ForEach(AIProviderID.allCases) { provider in
                let name = provider == .codex ? "Codex" : "Claude Code"
                SettingRow(title: name, subtitle: nil) {
                    DSToggle(isOn: Binding(get: { settings.aiUsageSources.contains(provider) }, set: { enabled in
                        if enabled { settings.aiUsageSources.insert(provider) }
                        else { settings.aiUsageSources.remove(provider) }
                    }), label: name)
                }
            }
            HairlineDivider()
            SettingRow(title: tr("刷新间隔"), subtitle: nil) {
                Picker(tr("刷新间隔"), selection: $settings.aiUsageRefreshMinutes) {
                    ForEach(AppSettings.aiUsageRefreshOptions, id: \.self) { value in
                        Text(tr("\(value) 分钟")).tag(value)
                    }
                }.labelsHidden()
            }
            Text(tr("仅统计本机日志，不代表订阅账单或其他设备的用量"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
