// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Metrics
import Localization
import Observation
import SwiftUI

enum IslandScene: Int, CaseIterable, Codable, Sendable {
    case system, ai, focus

    var title: String {
        switch self {
        case .system: tr("系统")
        case .ai: tr("AI 用量")
        case .focus: tr("休息")
        }
    }

    var symbol: String {
        switch self {
        case .system: "waveform.path.ecg"
        case .ai: "sparkles"
        case .focus: "timer"
        }
    }

    var tint: Color {
        switch self {
        case .system: .mint
        case .ai: .purple
        case .focus: .orange
        }
    }
}

/// 仅管理窗口展示；读数、账号和计时均由应用现有服务持有。
@MainActor @Observable
final class IslandModel {
    var presentation: IslandPresentation = .collapsed
    var scene: IslandScene = .system
}

@MainActor
struct IslandReading {
    let scene: IslandScene
    let appModel: AppModel

    private var settings: AppSettings { appModel.settings }
    private var rest: RestController { appModel.rest }
    var cpuValue: String {
        guard settings.isModuleEnabled(.cpu) else { return tr("尚未启用") }
        return appModel.store.cpu.map { $0.total.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)) } ?? "—"
    }
    var tokenValue: String {
        guard settings.aiUsageEnabled else { return tr("尚未启用") }
        return appModel.aiUsage.todayTokens.map { UsageNumber.short($0, westernUnits: settings.aiUsageWesternUnits) + " Tokens" } ?? "—"
    }
    func value(for metric: IslandSystemMetric) -> String {
        switch metric {
        case .cpu: return cpuValue
        case .memory:
            guard settings.isModuleEnabled(.memory) else { return tr("尚未启用") }
            return appModel.store.memory.map { Format.bytes($0.used, locale: L10n.locale) } ?? "—"
        case .temperature:
            guard settings.isModuleEnabled(.battery) else { return tr("尚未启用") }
            guard let value = appModel.store.sensors?.temperature(.cpu)?.maximum else { return "—" }
            let reading = Measurement(value: value, unit: UnitTemperature.celsius)
            return (settings.useFahrenheit ? reading.converted(to: .fahrenheit) : reading)
                .formatted(.measurement(width: .narrow, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))).locale(L10n.locale))
        case .power:
            guard settings.isModuleEnabled(.battery) else { return tr("尚未启用") }
            return appModel.store.power?.system.map(Format.watts) ?? "—"
        }
    }

    var compactValue: String {
        switch scene {
        case .system:
            let metric = settings.islandPreferences.primaryMetric
            return metric.title + " " + value(for: metric)
        case .ai:
            guard settings.aiUsageEnabled else { return tr("尚未启用") }
            if settings.aiUsageShowsLocalUsage { return tokenValue }
            // 灵动岛独立于菜单栏的服务选择，只复用其有效额度窗口口径。
            let quotas = appModel.aiUsage.usesMagpie ? appModel.aiUsage.magpieQuotaReadings()
                : MenuBarReading(model: appModel, items: [.aiUsage]).aiQuotas
            guard let quota = quotas.first else { return tr("暂无额度数据") }
            let percent = AIUsageFormat.quotaPercent(remainingPercent: quota.window.remainingPercent,
                showsRemaining: settings.aiQuotaShowsRemaining, locale: L10n.locale)
            return quota.sourceName + " " + tr(settings.aiQuotaShowsRemaining ? "剩余" : "已用") + " " + percent
        case .focus: return settings.restEnabled ? WellnessFormat.timer(rest.secondsRemaining) : tr("尚未启用")
        }
    }
}

struct IslandView: View {
    let model: IslandModel
    let appModel: AppModel
    var selectScene: (IslandScene) -> Void
    var expand: () -> Void
    var collapse: () -> Void
    var stop: () -> Void

    private var settings: AppSettings { appModel.settings }
    private var rest: RestController { appModel.rest }
    private var preferences: IslandPreferences { settings.islandPreferences.normalized }
    private var reading: IslandReading { IslandReading(scene: model.scene, appModel: appModel) }
    var cpuValue: String { reading.cpuValue }
    var tokenValue: String { reading.tokenValue }
    var compactValue: String { reading.compactValue }

    var body: some View {
        Group {
            switch model.presentation {
            case .collapsed:
                Button(action: expand) {
                    HStack(spacing: IslandCompactLayout.spacing) {
                        Image(systemName: model.scene.symbol).foregroundStyle(model.scene.tint).frame(width: IslandCompactLayout.iconWidth)
                        Text(compactValue).monospacedDigit().fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .frame(width: IslandCompactLayout.disclosureWidth)
                    }
                    .padding(.horizontal, IslandCompactLayout.horizontalPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(tr("展开灵动岛"))
                .accessibilityValue(compactValue)
            case .preview:
                Button(action: expand) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(model.scene.title, systemImage: model.scene.symbol).foregroundStyle(model.scene.tint)
                            Spacer()
                            Text("XStats").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(compactValue).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Spacer()
                            Text(tr("点击展开")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(tr("展开灵动岛"))
                .accessibilityValue(compactValue)
            case .expanded:
                expanded
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .environment(appModel)
        .environment(\.locale, L10n.locale(for: settings.language.resolved))
        .environment(\.layoutDirection, settings.language.resolved.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("XStats").fontWeight(.semibold)
                Spacer(minLength: 8)
                Button(action: collapse) { Image(systemName: "chevron.up").padding(5) }
                    .accessibilityLabel(tr("收起")).help(tr("收起"))
            }
            if preferences.scenes.count > 1 {
                HStack(spacing: 4) {
                    // macOS 15 可在后台构建列表行；模型读取延迟到行的 MainActor body。
                    MainActorForEach(preferences.scenes, id: \.rawValue) { scene in
                        Button { selectScene(scene) } label: {
                            Label(scene.title, systemImage: scene.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(model.scene == scene ? .white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .accessibilityAddTraits(model.scene == scene ? [.isSelected] : [])
                    }
                }
                .padding(3)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            sceneContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                Button(tr("打开 XStats 主窗口")) {
                    appModel.openMainWindow(model.scene == .system ? .overview : model.scene == .ai ? .aiUsage : .rest)
                    collapse()
                }
                Spacer(minLength: 0)
                Button(tr("关闭灵动岛"), action: stop)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(18)
    }

    @ViewBuilder private var sceneContent: some View {
        switch model.scene {
        case .system:
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(reading.value(for: preferences.primaryMetric)).font(.system(size: 34, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(preferences.primaryMetric.title).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "waveform.path.ecg").font(.system(size: 28)).foregroundStyle(.mint)
                }
                HStack(spacing: 10) {
                    MainActorForEach(Array(preferences.systemMetrics.dropFirst()), id: \.self) { item in
                        metric(item.title, value: reading.value(for: item))
                    }
                }
            }
        case .ai:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !settings.aiUsageEnabled { Text(tr("尚未启用")) }
                    else {
                        if settings.aiUsageShowsLocalUsage {
                            HStack(alignment: .firstTextBaseline) {
                                Text(tr("今日消耗的 Token")).font(.system(size: 10)).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(tokenValue).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            if let updated = appModel.aiUsage.usesMagpie ? appModel.aiUsage.magpieUsageUpdatedAt[.daily] : appModel.aiUsage.localState(for: nil).updated {
                                Text(updated, format: Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if appModel.aiUsage.usesMagpie ? appModel.aiUsage.magpieUsageFailures[.daily] != nil : appModel.aiUsage.localState(for: nil).stale {
                                Text(tr("显示上次成功读取的数据。")).font(.system(size: 10)).foregroundStyle(.orange)
                            }
                        }
                        if appModel.aiUsage.usesMagpie {
                            if appModel.aiUsage.magpieQuotaFailure != nil {
                                Text(tr("暂时无法连接额度服务")).foregroundStyle(.orange)
                            }
                            if let updated = appModel.aiUsage.magpieQuotaUpdatedAt,
                               appModel.aiUsage.magpieQuotaFailure != nil || !settings.aiUsageShowsLocalUsage {
                                Text(updated, format: Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if appModel.aiUsage.magpieQuotaFailure != nil, !appModel.aiUsage.magpieQuotas.isEmpty {
                                Text(tr("显示上次成功读取的数据。"))
                                    .font(.system(size: 10)).foregroundStyle(.orange)
                            }
                            if appModel.aiUsage.magpieQuotas.isEmpty { Text(tr("暂无额度数据")).foregroundStyle(.secondary) }
                            else { MagpieQuotaAccounts(accounts: appModel.aiUsage.magpieQuotas) }
                        } else {
                            MainActorForEach(appModel.aiUsage.visibleQuotaProviders(for: nil)) { provider in
                                quota(provider)
                            }
                            if appModel.aiUsage.visibleQuotaProviders(for: nil).isEmpty { Text(tr("暂无额度数据")).foregroundStyle(.secondary) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .focus:
            if !settings.restEnabled { Text(tr("尚未启用")).foregroundStyle(.secondary) }
            else {
                HStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(.orange.opacity(0.15), lineWidth: 5)
                        Circle().trim(from: 0, to: rest.phaseDuration > 0 ? min(1, max(0, 1 - rest.secondsRemaining / rest.phaseDuration)) : 0)
                            .stroke(.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: rest.isRunning ? "timer" : "pause.fill").font(.system(size: 24)).foregroundStyle(.orange)
                    }
                    .frame(width: 76, height: 76).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(rest.phase.title).foregroundStyle(.secondary)
                        Text(WellnessFormat.timer(rest.secondsRemaining)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Button(rest.primaryAction.title) { rest.startPause() }.foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func quota(_ provider: AIProviderID) -> some View {
        let state = appModel.aiUsage.visibleQuotaState(for: provider)
        return VStack(alignment: .leading, spacing: 8) {
            Text(provider == .codex ? "Codex" : "Claude Code").fontWeight(.semibold)
            if let snapshot = state.snapshot {
                MainActorForEach(snapshot.windows) { window in
                    HStack {
                        Text(quotaTitle(window.kind))
                        Spacer()
                        Text(tr(settings.aiQuotaShowsRemaining ? "剩余" : "已用"))
                        Text(AIUsageFormat.quotaPercent(remainingPercent: window.remainingPercent, showsRemaining: settings.aiQuotaShowsRemaining, locale: L10n.locale)).monospacedDigit()
                    }
                }
                Text(snapshot.fetchedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if state.isStale { Text(tr("显示上次成功读取的数据。")).font(.system(size: 10)).foregroundStyle(.orange) }
                if state.failure != nil { Text(quotaStatus(for: provider)).foregroundStyle(.orange) }
            } else if state.isRefreshing {
                ProgressView().controlSize(.small)
            } else { Text(quotaStatus(for: provider)).foregroundStyle(.secondary) }
        }
    }

    func quotaStatus(for provider: AIProviderID) -> String {
        switch appModel.aiUsage.visibleQuotaState(for: provider).failure {
        case nil: tr("暂无额度数据")
        case .notConfigured: tr("未检测到登录凭据，请先登录对应 CLI")
        case .unauthorized: tr("登录已失效，请在对应 CLI 重新登录")
        case .rateLimited: tr("服务暂时限流，稍后会自动重试")
        case .network: tr("暂时无法连接额度服务")
        case .invalidResponse: tr("额度接口返回了无法识别的数据")
        }
    }

    private func quotaTitle(_ kind: AIQuotaKind) -> String {
        switch kind {
        case .session: tr("5 小时")
        case .weekly: tr("7 天")
        case .opusWeekly: "Opus · " + tr("7 天")
        case .sonnetWeekly: "Sonnet · " + tr("7 天")
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
