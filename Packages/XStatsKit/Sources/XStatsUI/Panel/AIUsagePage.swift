// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Localization
import Metrics
import SwiftUI

struct AIUsagePage: View {
    var body: some View {
        PageScroll { AIUsageContent(showsSettings: true) }
    }
}

struct AIUsagePopover: View {
    var body: some View { AIUsageContent(showsSettings: false) }
}

private struct AIUsageContent: View {
    let showsSettings: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DS.Space.s3) {
            controls
            if model.settings.aiUsageEnabled {
                CodexUsageSection(state: model.aiUsage.state(for: .codex), mode: model.settings.aiUsageDisplayMode)
            } else {
                enableCard
            }
            if showsSettings { settingsCard }
            if let updated = model.aiUsage.lastSuccessfulRefreshAt, model.settings.aiUsageEnabled {
                HStack {
                    Text(tr("上次检查：\(updated.formatted(date: .omitted, time: .shortened))"))
                    Spacer()
                    Text(tr("\(model.settings.aiUsageRefreshMinutes) 分钟"))
                }
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 1),
                   value: model.settings.aiUsageEnabled)
    }

    private var controls: some View {
        @Bindable var settings = model.settings
        return HStack(spacing: DS.Space.s2) {
            SegmentedControl(selection: $settings.aiUsageDisplayMode,
                             options: AIUsageDisplayMode.allCases.map { ($0, $0.title) })
                .frame(width: DS.Size.sidebarWidth - DS.Space.s8)
            Spacer(minLength: DS.Space.s2)
            MiniIconButton(systemName: model.aiUsage.isRefreshing ? "hourglass" : "arrow.clockwise",
                           help: model.aiUsage.isRefreshing ? tr("正在刷新") : tr("立即刷新")) {
                Task { await model.aiUsage.refresh() }
            }
            .disabled(!settings.aiUsageEnabled || model.aiUsage.isRefreshing ||
                      (model.aiUsage.state(for: .codex).failure?.retryAt.map { $0 > Date() } ?? false))
        }
    }

    private var enableCard: some View {
        Card {
            CardHeader(icon: "sparkles", title: tr("Codex 配额"), detail: tr("默认关闭"))
            Text(tr("XStats 只读 Codex CLI 的本机登录凭据，并直接向 ChatGPT 查询订阅配额；不会保存、刷新或修改登录信息。"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(tr("启用 Codex 配额")) {
                model.settings.aiUsageEnabled = true
            }
            .buttonStyle(DSButtonStyle(kind: .primary))
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private var settingsCard: some View {
        @Bindable var settings = model.settings
        return Card {
            CardHeader(icon: "gearshape", title: tr("数据来源"), detail: tr("本机设置"))
            SettingRow(title: tr("跟踪 Codex"), subtitle: tr("关闭后停止读取凭据和查询配额")) {
                DSToggle(isOn: Binding(get: { settings.aiUsageEnabled }, set: { value in
                    settings.aiUsageEnabled = value
                }), label: tr("跟踪 Codex"))
            }
            HairlineDivider()
            SettingRow(title: tr("菜单栏"), subtitle: tr("Codex · 自动显示最紧张的配额")) {
                Picker(tr("菜单栏"), selection: $settings.aiUsageFocus) {
                    Text(tr("自动")).tag(AIQuotaKind?.none)
                    ForEach(AIQuotaKind.allCases) { kind in
                        Text(kind.title).tag(AIQuotaKind?.some(kind))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            HairlineDivider()
            SettingRow(title: tr("刷新间隔"), subtitle: tr("配额查询独立于系统指标刷新")) {
                Picker(tr("刷新间隔"), selection: Binding(get: { settings.aiUsageRefreshMinutes }, set: { value in
                    settings.aiUsageRefreshMinutes = value
                })) {
                    ForEach(AppSettings.aiUsageRefreshOptions, id: \.self) { minutes in
                        Text(tr("\(minutes) 分钟")).tag(minutes)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text(tr("凭据始终由 Codex CLI 管理。登录过期时，请回到 Codex CLI 重新登录。"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CodexUsageSection: View {
    let state: AIUsageProviderState
    let mode: AIUsageDisplayMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Card {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "terminal")
                    .font(.system(size: DS.TextSize.sm.rawValue, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                Text("Codex").dsFont(.sm, weight: .semibold)
                Spacer(minLength: DS.Space.s2)
                if let plan = state.snapshot?.planName {
                    TagBadge(text: plan, tone: .neutral, compact: true)
                }
            }

            if let snapshot = state.snapshot {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Space.s2) {
                    ForEach(snapshot.windows) { window in
                        AIQuotaTile(window: window, mode: mode)
                    }
                }
                if let credits = snapshot.remainingCredits {
                    InfoRow(label: tr("积分"), text: tr("剩余 \(credits.formatted(.number.precision(.fractionLength(0...1))))"))
                }
            } else if state.isRefreshing {
                HStack(spacing: DS.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(tr("正在检查本机登录…"))
                }
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
            } else {
                AIUsageFailureView(failure: state.failure)
            }

            if state.isStale, let failure = state.failure {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 1), value: state)
    }
}

private struct AIQuotaTile: View {
    let window: AIQuotaWindow
    let mode: AIUsageDisplayMode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
                    Text(window.kind.title).dsFont(.xs, weight: .medium)
                    Spacer(minLength: DS.Space.s1)
                    Text(Format.percent(displayedFraction))
                        .dsFont(.sm, weight: .semibold)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: displayedFraction))
                }
                ProgressTrack(fraction: displayedFraction, color: riskColor, height: DS.Space.s1)
                if let reset = window.resetsAt {
                    HStack(spacing: DS.Space.s1) {
                        Image(systemName: "clock")
                        Text(reset, style: .relative)
                        Text(tr("后重置"))
                    }
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                }
            }
            .padding(DS.Space.s2)
            .background(DS.Palette.track, in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(window.kind.title)，\(Format.percent(displayedFraction))，\(mode.title)")
        }
    }

    private var displayedFraction: Double {
        switch mode {
        case .used: min(max(window.usedPercent / 100, 0), 1)
        case .remaining: max(0, 1 - min(max(window.usedPercent / 100, 0), 1))
        }
    }

    private var riskColor: Color {
        switch window.usedPercent {
        case 85...: DS.Palette.error
        case 60..<85: DS.Palette.warning
        default: DS.Palette.primary
        }
    }
}

private struct AIUsageFailureView: View {
    let failure: AIUsageFailure?

    var body: some View {
        Label(failure?.message ?? tr("暂无配额数据"), systemImage: failure?.symbol ?? "chart.bar.xaxis")
            .dsFont(.xs)
            .foregroundStyle(failure == nil ? DS.Palette.textSecondary : DS.Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension AIUsageDisplayMode {
    var title: String {
        switch self {
        case .remaining: tr("剩余")
        case .used: tr("已用")
        }
    }
}

private extension AIQuotaKind {
    var title: String {
        switch self {
        case .session: tr("会话")
        case .weekly: tr("周配额")
        case .sparkSession: "Spark"
        case .sparkWeekly: tr("Spark 周配额")
        }
    }
}

private extension AIUsageFailure {
    var message: String {
        switch self {
        case .notConfigured: tr("尚未登录 Codex，请先在 Codex CLI 中登录。")
        case .apiKeyUnsupported: tr("API Key 无法查询 ChatGPT 订阅配额。")
        case .invalidCredentials: tr("Codex 登录凭据无法读取，请重新登录。")
        case .unauthorized: tr("Codex 登录已过期，请重新登录。")
        case .rateLimited(let retryAt): retryAt.map { tr("查询过于频繁，可在 \($0.formatted(date: .omitted, time: .shortened)) 后重试。") }
            ?? tr("查询过于频繁，请稍后重试。")
        case .network: tr("暂时无法连接 Codex 配额服务。")
        case .invalidResponse: tr("Codex 返回了无法识别的配额数据。")
        case .server(let status): tr("Codex 配额服务暂时不可用（HTTP \(status)）。")
        }
    }

    var symbol: String {
        switch self {
        case .notConfigured, .apiKeyUnsupported, .invalidCredentials, .unauthorized: "person.crop.circle.badge.exclamationmark"
        case .rateLimited: "hourglass"
        case .network, .invalidResponse, .server: "exclamationmark.triangle"
        }
    }
}
