// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Localization
import SwiftUI

extension EnvironmentValues {
    @Entry var aiUsageWesternUnits = false
}

private struct CostRefreshKey: Hashable {
    let attempt: Date?
    let currency: AIUsageCurrency
    let enabled: Bool
    let localUsage: Bool
    let visible: Bool
}

struct AIUsagePage: View {
    var body: some View { PageScroll { LocalUsageContent(compact: false) } }
}
struct AIUsagePopover: View {
    var body: some View { LocalUsageContent(compact: true) }
}

private struct LocalUsageContent: View {
    @Environment(\.isSnapshot) private var isSnapshot
    let compact: Bool
    @Environment(AppModel.self) private var model
    @State private var selectedModel = ""
    @State private var source = "all"
    @State private var activityMode = UsageActivityMode.daily

    private var enabledProviders: [AIProviderID] {
        AIProviderID.allCases.filter { model.settings.aiUsageSources.contains($0) }
    }

    private var provider: AIProviderID? {
        if enabledProviders.count == 1 { return enabledProviders.first }
        return AIProviderID(rawValue: source).flatMap { model.settings.aiUsageSources.contains($0) ? $0 : nil }
    }
    private var sourceOptions: [(String, String)] {
        [("all", tr("全部"))] + enabledProviders
            .map { ($0.rawValue, $0 == .codex ? "Codex" : "Claude") }
    }
    private var sourceTitle: String {
        if let provider { return provider == .codex ? "Codex" : "Claude Code" }
        return enabledProviders
            .map { $0 == .codex ? "Codex" : "Claude Code" }.joined(separator: " + ")
    }

    private var isVisible: Bool {
        compact ? model.openPopover == .aiUsage
            : model.isMainWindowVisible && model.settings.panelTab == .aiUsage
    }

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: compact ? DS.Space.s3 : DS.Space.s4) {
            toolbar
            if model.settings.aiUsageEnabled && !enabledProviders.isEmpty {
                Text(sourceTitle)
                    .dsFont(.sm, weight: .semibold)
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            if !model.aiUsage.visibleQuotaProviders(for: provider).isEmpty {
                quotaSection
            }
            if !model.settings.aiUsageEnabled {
                Card {
                    Label(tr("AI 用量"), systemImage: "chart.bar").dsFont(.base, weight: .semibold)
                    Text(tr("查看 Codex / Claude 的 Token 用量与订阅额度。"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(tr("启用 AI 用量")) { model.settings.aiUsageEnabled = true }
                        .buttonStyle(DSButtonStyle(kind: .primary))
                }
            } else if model.settings.aiUsageSources.isEmpty {
                Card {
                    Text(tr("数据来源") + " · " + tr("尚未启用")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
                    Button(tr("设置")) { model.openAIUsageSettings() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            } else if model.settings.aiUsageShowsLocalUsage {
                if let report = model.aiUsage.localReport(for: provider) {
                    let rows = report.summary(mode: activityMode, model: selectedModel.isEmpty ? nil : selectedModel, now: now)
                    let activityRows = report.selected(days: 365, model: selectedModel.isEmpty ? nil : selectedModel, now: now)
                    let total = LocalUsageReport.total(rows)
                    UsageSummary(total: total, compact: compact,
                                 title: selectedModel.isEmpty ? tr("本地用量") : selectedModel,
                                 costRows: rows)
                    UsageActivityPanel(rows: activityRows, compact: compact, now: now, mode: $activityMode)
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
            } else if model.aiUsage.visibleQuotaProviders(for: provider).isEmpty {
                Card { Text(tr("暂无额度数据")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary) }
            }
        }
        .environment(\.aiUsageWesternUnits, model.settings.aiUsageWesternUnits)
        .task(id: CostRefreshKey(attempt: model.aiUsage.lastAttemptAt, currency: model.settings.aiUsageCurrency,
                                 enabled: model.settings.aiUsageEnabled, localUsage: model.settings.aiUsageShowsLocalUsage,
                                 visible: isVisible)) {
            guard !isSnapshot, isVisible else { return }
            await model.aiUsage.refreshCostReferences()
        }
        .onChange(of: model.settings.aiUsageSources) { _, sources in
            if let id = AIProviderID(rawValue: source), !sources.contains(id) { source = "all" }
            selectedModel = ""
        }
    }

    @ViewBuilder private var toolbar: some View {
        if !compact || (model.settings.aiUsageEnabled && enabledProviders.count > 1) {
            HStack(spacing: DS.Space.s2) {
                if model.settings.aiUsageEnabled && enabledProviders.count > 1 {
                    UsageChoices(selection: $source, options: sourceOptions,
                                 label: tr("数据来源"))
                        .frame(maxWidth: compact ? .infinity : 260)
                        .onChange(of: source) { _, _ in selectedModel = "" }
                }
                if !compact {
                    Spacer(minLength: DS.Space.s4)
                    AIUsageRefreshButton()
                    AIUsageSettingsButton()
                }
            }
        }
    }

    private var quotaSection: some View {
        Card(spacing: DS.Space.s3) {
            let visibleProviders = model.aiUsage.visibleQuotaProviders(for: provider)
            HStack(spacing: DS.Space.s1) {
                Text(tr("订阅额度")).dsFont(.sm, weight: .semibold)
                Image(systemName: "info.circle")
                    .font(.system(size: DS.TextSize.xs.rawValue))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .help(tr("服务端用量 · 与本机 Token 统计不同"))
                    .accessibilityLabel(tr("服务端用量 · 与本机 Token 统计不同"))
                Spacer()
                if let provider, model.aiUsage.visibleQuotaState(for: provider).snapshot?.source == .sub2api {
                    Text("Sub2API").dsFont(.xs, weight: .medium)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            ForEach(visibleProviders) { id in
                let state = model.aiUsage.visibleQuotaState(for: id)
                VStack(alignment: .leading, spacing: DS.Space.s3) {
                    if provider == nil {
                        HStack {
                            Text(id == .codex ? "Codex" : "Claude Code").dsFont(.xs, weight: .semibold)
                            Spacer()
                            if state.snapshot?.source == .sub2api {
                                Text("Sub2API").dsFont(.xs, weight: .medium)
                                    .foregroundStyle(DS.Palette.textTertiary)
                            }
                        }
                    }
                    if let snapshot = state.snapshot {
                        ForEach(snapshot.windows) { window in
                            VStack(alignment: .leading, spacing: DS.Space.s1) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(quotaTitle(window.kind))
                                        .foregroundStyle(DS.Palette.textSecondary)
                                    Spacer()
                                    Text(tr(model.settings.aiQuotaShowsRemaining ? "剩余" : "已用"))
                                        .foregroundStyle(DS.Palette.textSecondary)
                                    Text(AIUsageFormat.quotaPercent(remainingPercent: window.remainingPercent,
                                                                  showsRemaining: model.settings.aiQuotaShowsRemaining,
                                                                  locale: L10n.locale))
                                        .monospacedDigit()
                                        .foregroundStyle(DS.Palette.textPrimary)
                                }
                                .dsFont(.xs)
                                ProgressTrack(fraction: (AIUsageFormat.quotaValue(remainingPercent: window.remainingPercent,
                                                                               showsRemaining: model.settings.aiQuotaShowsRemaining) ?? 0) / 100,
                                              color: progressTint(for: window.remainingPercent))
                                    .accessibilityLabel(quotaTitle(window.kind) + " " + tr(model.settings.aiQuotaShowsRemaining ? "剩余" : "已用")
                                        + " " + AIUsageFormat.quotaPercent(remainingPercent: window.remainingPercent,
                                                                          showsRemaining: model.settings.aiQuotaShowsRemaining,
                                                                          locale: L10n.locale))
                                if let reset = window.resetsAt {
                                    let resetText = tr("重置：") + " " + reset.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))
                                    if state.isStale {
                                        Text(resetText)
                                            .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                                    } else {
                                        TimelineView(.periodic(from: .now, by: 60)) { context in
                                            let fraction = window.remainingTimeFraction(at: context.date)
                                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
                                                Text(resetText)
                                                    .foregroundStyle(DS.Palette.textTertiary)
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.8)
                                                Spacer(minLength: DS.Space.s1)
                                                if let fraction {
                                                    Text("\(Int((fraction * 100).rounded()))%")
                                                        .monospacedDigit()
                                                        .foregroundStyle(DS.Palette.textSecondary)
                                                }
                                            }
                                            .dsFont(.xs)
                                            if let fraction {
                                                // 条长表示距离重置的剩余时间，与右侧百分比一致。
                                                ProgressTrack(fraction: fraction, color: DS.Palette.primary)
                                                    .accessibilityLabel(tr("距重置"))
                                                    .accessibilityValue("\(Int((fraction * 100).rounded()))%")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        // Sub2API 的 Fable 窗口可能为 null；显示缺失状态，不推断为 0% 已用。
                        if id == .claude, snapshot.source == .sub2api,
                           snapshot.window(.fableWeekly) == nil {
                            HStack {
                                Text(quotaTitle(.fableWeekly))
                                Spacer()
                                Text(tr("暂无额度数据"))
                            }
                            .dsFont(.xs)
                            .foregroundStyle(DS.Palette.textTertiary)
                        }
                        if state.isStale {
                            VStack(alignment: .leading, spacing: DS.Space.s1) {
                                Label(tr("上次额度"), systemImage: "clock")
                                    .foregroundStyle(DS.Palette.warning)
                                Text(tr("上次成功：\(snapshot.fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))"))
                                    .foregroundStyle(DS.Palette.textTertiary)
                                if let lastAttemptAt = state.lastAttemptAt {
                                    Text(tr("最近刷新：\(lastAttemptAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))"))
                                        .foregroundStyle(DS.Palette.textTertiary)
                                }
                                if state.failure != nil {
                                    Text(quotaFailureText(state.failure))
                                        .foregroundStyle(DS.Palette.warning)
                                }
                            }
                            .dsFont(.xs)
                        } else if let lastAttemptAt = state.lastAttemptAt {
                            Text(tr("最近刷新：\(lastAttemptAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: L10n.locale)))"))
                                .dsFont(.xs)
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                    } else if state.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(quotaFailureText(state.failure))
                            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                if id != visibleProviders.last {
                    HairlineDivider()
                }
            }
        }
    }

    private func quotaTitle(_ kind: AIQuotaKind) -> String {
        switch kind {
        case .session: tr("5 小时")
        case .weekly: tr("7 天")
        case .fableWeekly: "Fable · " + tr("7 天")
        case .opusWeekly: "Opus · " + tr("7 天")
        case .sonnetWeekly: "Sonnet · " + tr("7 天")
        }
    }

    private func progressTint(for percent: Double) -> Color {
        if percent <= 10 { return DS.Palette.critical }
        if percent <= 20 { return DS.Palette.error }
        if percent < 40 { return DS.Palette.warning }
        if percent < 80 { return DS.Palette.primary }
        return DS.Palette.success
    }

    private func quotaFailureText(_ failure: AIQuotaFailure?) -> String {
        switch failure {
        case nil: tr("暂无额度数据")
        case .notConfigured: tr("未检测到登录凭据，请先登录对应 CLI")
        case .unauthorized: tr("登录已失效，请在对应 CLI 重新登录")
        case .rateLimited: tr("服务暂时限流，稍后会自动重试")
        case .network: tr("暂时无法连接额度服务")
        case .invalidResponse: tr("额度接口返回了无法识别的数据")
        case .sub2apiConfiguration: tr("Sub2API 配置无法读取，请检查设置")
        case .sub2apiUnauthorized: tr("Sub2API 登录失败，请检查管理员邮箱和密码")
        case .sub2apiNetwork: tr("暂时无法连接 Sub2API")
        case .sub2apiInvalidResponse: tr("Sub2API 返回了无法识别的额度数据")
        case .sub2apiAccountMismatch: tr("Sub2API 账号平台与所选来源不匹配")
        }
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
                    Text(tr("上次检查：\(updated.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: L10n.locale)))"))
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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

/// 所有数字和日期都跟随应用语言（`L10n.locale`），不跟随系统语言：
/// 否则中文系统 + 英文界面下，坐标轴、悬停提示和时间会夹在英文文案里显示中文。
enum UsageNumber {
    static func exact(_ value: Int, locale: Locale = L10n.locale) -> String {
        value.formatted(.number.locale(locale))
    }

    static func day(_ date: Date, locale: Locale = L10n.locale) -> String {
        date.formatted(.dateTime.year().month().day().locale(locale))
    }

    static func short(_ value: Int, locale: Locale = L10n.locale, westernUnits: Bool = false) -> String {
        AIUsageFormat.tokens(value, westernUnits: westernUnits, locale: locale)
    }
}

private struct UsageSummary: View {
    @Environment(\.aiUsageWesternUnits) private var westernUnits
    let total: ModelTokenUsage
    let compact: Bool
    let title: String
    let costRows: [ModelTokenUsage]
    @State private var expanded = false

    var body: some View {
        Card(padding: DS.Space.s6, spacing: compact ? DS.Space.s3 : DS.Space.s6) {
            HStack {
                Text(title).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Text(UsageNumber.short(total.total, westernUnits: westernUnits))
                    .dsFont(.xxl, weight: .semibold)
                    .tracking(-0.6).monospacedDigit()
                    .help(UsageNumber.exact(total.total))
                    .accessibilityLabel(UsageNumber.exact(total.total) + " Tokens")
                Text("Tokens").dsFont(.sm).foregroundStyle(DS.Palette.textTertiary)
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: compact ? 2 : 4),
                      alignment: .leading, spacing: DS.Space.s3) {
                UsageMetric(title: tr("输入 Token"), value: UsageNumber.short(total.input, westernUnits: westernUnits), exact: UsageNumber.exact(total.input))
                UsageMetric(title: tr("输出 Token"), value: UsageNumber.short(total.output, westernUnits: westernUnits), exact: UsageNumber.exact(total.output))
                UsageMetric(title: tr("缓存命中率"), value: total.input > 0
                    ? (Double(total.cached) / Double(total.input)).formatted(.percent.precision(.fractionLength(1)).locale(L10n.locale)) : "—")
                UsageMetric(title: tr("用量记录"), value: UsageNumber.exact(total.records))
            }
            UsageCostSummary(rows: costRows)
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: DS.Space.s2) {
                    InfoRow(label: tr("缓存 Token"), text: UsageNumber.exact(total.cached))
                    InfoRow(label: tr("缓存创建 Token"), text: UsageNumber.exact(total.cacheCreated))
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

private struct UsageCostSummary: View {
    let rows: [ModelTokenUsage]
    @Environment(AppModel.self) private var model

    var body: some View {
        let estimate = model.aiUsage.estimatedCost(rows)
        let references = model.aiUsage.costReferences
        let currency = model.settings.aiUsageCurrency
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack {
                Text(tr("估算费用")).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                if let usd = estimate.usd {
                    if let amount = AIUsageFormat.money(usd: usd, currency: currency,
                                                       usdToCNY: references.exchangeRate?.cnyPerUSD, locale: L10n.locale) {
                        Text(amount + (estimate.unpricedModels.isEmpty ? "" : "+"))
                            .monospacedDigit().foregroundStyle(DS.Palette.textPrimary)
                    } else {
                        Text(tr("暂无汇率")).foregroundStyle(DS.Palette.textTertiary)
                    }
                } else if model.aiUsage.isRefreshingCostReferences {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(tr("暂无价格")).foregroundStyle(DS.Palette.textTertiary)
                }
            }.dsFont(.sm, weight: .medium)
            Text(tr("按模型基础 API 单价估算，不含阶梯加价，非订阅账单。"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !estimate.unpricedModels.isEmpty {
                Text(tr("部分模型暂无价格"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.warning)
                    .help(estimate.unpricedModels.joined(separator: "\n"))
            }
            if let catalog = references.catalog {
                Text(tr("价格更新：\(catalog.fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
            if currency == .cny, let rate = references.exchangeRate {
                let value = rate.cnyPerUSD.formatted(.number.precision(.fractionLength(0...4)).locale(L10n.locale))
                Text(tr("参考汇率：1 USD ≈ \(value) CNY"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    .help(tr("汇率更新：\(rate.fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))"))
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
    @Environment(\.aiUsageWesternUnits) private var westernUnits
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
                Text(UsageNumber.short(item.total, westernUnits: westernUnits)).dsFont(.sm, weight: .semibold)
                    .monospacedDigit().fixedSize().help(UsageNumber.exact(item.total))
                    .accessibilityLabel(UsageNumber.exact(item.total) + " Tokens")
                Text((total > 0 ? Double(item.total) / Double(total) : 0).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    .monospacedDigit().frame(width: DS.Space.s12, alignment: .trailing)
            }
            ProgressTrack(fraction: total > 0 ? Double(item.total) / Double(total) : 0,
                          color: DS.Palette.primary, height: DS.Space.s1 / 2, showsTrack: false)
                .accessibilityHidden(true)
            if !compact {
                HStack(spacing: DS.Space.s6) {
                    Text(tr("输入 Token") + "  " + UsageNumber.short(item.input, westernUnits: westernUnits))
                    Text(tr("输出 Token") + "  " + UsageNumber.short(item.output, westernUnits: westernUnits))
                    Spacer()
                    Text(tr("用量记录") + "  " + UsageNumber.exact(item.records))
                }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
            }
        }.padding(.vertical, DS.Space.s1)
    }
}

/// 摘要和图表共用筛选范围；短周期看柱状分布，累计看年度每日热力图。
private struct UsageActivityPanel: View {
    @Environment(\.aiUsageWesternUnits) private var westernUnits
    let rows: [ModelTokenUsage]
    let compact: Bool
    let now: Date
    @Binding var mode: UsageActivityMode
    @State private var hovered: String?

    var body: some View {
        Card(spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Text(tr("Token 活动")).dsFont(.sm, weight: .semibold)
                Spacer(minLength: DS.Space.s2)
                if !compact { choices.frame(width: 280) }
            }
            if compact { choices }
            Text(hovered ?? tr(mode == .daily ? "按小时统计" : "按天统计"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: DS.Space.s6)
            if mode == .cumulative {
                let activity = UsageActivity(rows: rows, now: now)
                if compact {
                    ScrollView(.horizontal) {
                        ActivityGrid(activity: activity, hovered: $hovered, side: DS.Space.s3)
                            .frame(height: gridHeight)
                    }.defaultScrollAnchor(.trailing)
                } else {
                    ActivityGrid(activity: activity, hovered: $hovered).frame(height: gridHeight)
                }
                Text(UsageNumber.day(activity.start) + " – " + UsageNumber.day(activity.end))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                HStack {
                    Text(tr("单日最高：\(UsageNumber.short(activity.peak, westernUnits: westernUnits)) Tokens"))
                        .help(UsageNumber.exact(activity.peak) + " Tokens")
                    Spacer(minLength: DS.Space.s1)
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: DS.Space.s1 / 2)
                            .fill(level == 0 ? DS.Palette.track : DS.Palette.primary.opacity(Double(level) / 4))
                            .frame(width: DS.Space.s3, height: DS.Space.s3)
                    }
                }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            } else {
                let series = UsageTimeSeries(rows: rows, mode: mode, now: now)
                if series.hasMissingHourlyData {
                    Text(tr("暂无小时明细，请刷新用量。"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    UsageBarChart(buckets: series.buckets, hourly: mode == .daily, hovered: $hovered)
                }
            }
        }
        .onChange(of: mode) { _, _ in hovered = nil }
        .onChange(of: rows) { _, _ in hovered = nil }
    }

    private var choices: some View {
        UsageChoices(selection: $mode, options: [(.daily, tr("今天")), (.weekly, tr("7 天")),
                                                (.monthly, tr("30 天")), (.cumulative, tr("累计"))],
                     label: tr("Token 活动"))
    }
    private var gridHeight: CGFloat { 7 * DS.Space.s3 + 6 * (DS.Space.s1 / 2) + DS.Space.s6 }
}

private struct UsageBarChart: View {
    @Environment(\.aiUsageWesternUnits) private var westernUnits
    let buckets: [UsageTimeSeries.Bucket]
    let hourly: Bool
    @Binding var hovered: String?

    var body: some View {
        let peak = max(1, buckets.map(\.total).max() ?? 0)
        VStack(spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                VStack(alignment: .trailing) {
                    Text(UsageNumber.short(peak, westernUnits: westernUnits))
                    Spacer()
                    Text(UsageNumber.short(peak / 2, westernUnits: westernUnits))
                    Spacer()
                    Text("0")
                }.dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    .frame(width: 48, alignment: .trailing).accessibilityHidden(true)
                GeometryReader { geometry in
                    ZStack {
                        VStack { HairlineDivider(); Spacer(); HairlineDivider(); Spacer(); HairlineDivider() }
                            .accessibilityHidden(true)
                        HStack(alignment: .bottom, spacing: DS.Space.s1 / 2) {
                            ForEach(buckets) { bucket in
                                let label = bucket.start.formatted(hourly
                                    ? .dateTime.month().day().hour().minute().timeZone().locale(L10n.locale)
                                    : .dateTime.month().day().locale(L10n.locale))
                                    + " · " + UsageNumber.exact(bucket.total) + " Tokens"
                                RoundedRectangle(cornerRadius: DS.Space.s1 / 2)
                                    .fill(DS.Palette.primary.opacity(0.8))
                                    .frame(maxWidth: 24)
                                    .frame(height: bucket.total == 0 ? 0 : max(2, geometry.size.height * Double(bucket.total) / Double(peak)))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                    .contentShape(Rectangle())
                                    .onHover { active in hovered = active ? label : nil }
                                    .accessibilityElement(children: .ignore).accessibilityLabel(label)
                            }
                        }
                    }
                }
            }.frame(height: 140)
            GeometryReader { geometry in
                let indices = buckets.count == 7 ? [0, 2, 4, 6]
                    : Array(Set([0, buckets.count / 4, buckets.count / 2, buckets.count * 3 / 4, max(0, buckets.count - 1)])).sorted()
                ForEach(indices, id: \.self) { index in
                    if buckets.indices.contains(index) {
                        Text(buckets[index].start.formatted(hourly
                            ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(L10n.locale)
                            : .dateTime.month(.twoDigits).day(.twoDigits).locale(L10n.locale)))
                            .position(x: min(geometry.size.width - 20, max(20, geometry.size.width * (Double(index) + 0.5) / Double(buckets.count))), y: 9)
                    }
                }
            }.frame(height: 20).padding(.leading, 48 + DS.Space.s2)
                .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary).accessibilityHidden(true)
        }
        // 时间轴固定从左到右，阿拉伯语标签仍按其文字方向排版。
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct ActivityGrid: View {
    let activity: UsageActivity
    @Binding var hovered: String?
    var side: CGFloat?
    private var gap: CGFloat { DS.Space.s1 / 2 }

    var body: some View {
        if let side {
            grid(side: side)
        } else {
            GeometryReader { geometry in
                grid(side: min(DS.Space.s3,
                               max(1, (geometry.size.width - CGFloat(activity.weeks.count - 1) * gap)
                                   / CGFloat(max(1, activity.weeks.count)))))
            }
        }
    }

    private func grid(side: CGFloat) -> some View {
        let peak = max(1, activity.peak)
        return HStack(alignment: .top, spacing: gap) {
            ForEach(activity.weeks) { week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        if let date = week.days[row] {
                            let count = activity.daily[date] ?? 0
                            let level = min(4, max(1, Int(ceil(Double(count) / Double(peak) * 4))))
                            ActivityCell(side: side,
                                color: count == 0 ? DS.Palette.track : DS.Palette.primary.opacity(Double(level) / 4),
                                label: UsageNumber.day(date) + " · " + UsageNumber.exact(count) + " Tokens",
                                hovered: $hovered)
                        } else {
                            Color.clear.frame(width: side, height: side).accessibilityHidden(true)
                        }
                    }
                    Color.clear.frame(width: side, height: DS.Space.s4)
                        .overlay(alignment: .leading) {
                            if let month = week.days.compactMap({ $0 }).first(where: { Calendar.current.component(.day, from: $0) == 1 }) {
                                Text(month.formatted(.dateTime.month(.abbreviated).locale(L10n.locale)))
                                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).fixedSize()
                            }
                        }
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

struct AIUsageRefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            MiniIconButton(systemName: "arrow.clockwise", help: tr("立即刷新")) {
                Task { await model.aiUsage.refresh() }
            }
            .opacity(model.aiUsage.isRefreshing ? 0 : 1)
            .disabled(!model.settings.aiUsageEnabled || model.settings.aiUsageSources.isEmpty || model.aiUsage.isRefreshing)
            if model.aiUsage.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel(tr("正在刷新")) }
        }
        .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
    }
}

struct AIUsageSettingsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MiniIconButton(systemName: "slider.horizontal.3", help: tr("AI 用量") + " · " + tr("设置")) {
            model.openAIUsageSettings()
        }
    }
}

struct AIUsageSettingsPanel: View {
    var body: some View {
        ScrollView { UsageSettings().padding(DS.Space.s4) }
            .frame(minWidth: 390, minHeight: 480)
            .background(DS.Palette.background)
            .appLanguageEnvironment()
    }
}

private struct UsageSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text(tr("设置")).dsFont(.base, weight: .semibold)
            SettingRow(title: tr("AI 用量"), subtitle: nil) {
                DSToggle(isOn: $settings.aiUsageEnabled, label: tr("AI 用量"))
            }
            SettingRow(title: tr("显示本地用量"),
                       subtitle: tr("读取本机会话日志；关闭后停止扫描并隐藏 Token 统计。")) {
                DSToggle(isOn: $settings.aiUsageShowsLocalUsage, label: tr("显示本地用量"))
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
                if settings.aiUsageEnabled && settings.aiUsageSources.contains(provider) {
                    let quota = model.aiUsage.visibleQuotaState(for: provider)
                    Sub2APISettingsView(provider: provider,
                                        directAvailable: quota.snapshot?.source == .direct,
                                        needsFallback: quota.snapshot?.source != .direct
                                            && (quota.failure != nil || quota.snapshot?.source == .sub2api))
                }
            }
            HairlineDivider()
            SettingRow(title: tr("刷新间隔"), subtitle: tr("AI 用量与额度共用此间隔；新数据到达后更新菜单栏。")) {
                Picker(tr("刷新间隔"), selection: $settings.aiUsageRefreshMinutes) {
                    ForEach(AppSettings.aiUsageRefreshOptions, id: \.self) { value in
                        Text(tr("\(value) 分钟")).tag(value)
                    }
                }.labelsHidden()
            }
            SettingRow(title: tr("额度显示"), subtitle: nil) {
                Picker(tr("额度显示"), selection: $settings.aiQuotaShowsRemaining) {
                    Text(tr("已用")).tag(false)
                    Text(tr("剩余")).tag(true)
                }.labelsHidden()
            }
            if settings.language.resolved.isChinese {
                SettingRow(title: tr("数字单位"), subtitle: nil) {
                    Picker(tr("数字单位"), selection: $settings.aiUsageWesternUnits) {
                        Text(tr("万 / 亿")).tag(false)
                        Text("K / M / B").tag(true)
                    }.labelsHidden()
                }
            }
            SettingRow(title: tr("货币"), subtitle: nil) {
                Picker(tr("货币"), selection: $settings.aiUsageCurrency) {
                    Text(tr("美元")).tag(AIUsageCurrency.usd)
                    Text(tr("人民币")).tag(AIUsageCurrency.cny)
                }.labelsHidden()
            }
            Text(tr("价格来源：models.dev；人民币按缓存汇率换算。"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("本机 Token 统计不代表订阅账单或其他设备的用量"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
