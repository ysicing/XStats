// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Metrics
import Localization
import Observation
import SwiftUI

enum IslandScene: Int, CaseIterable, Codable, Sendable {
    case system, ai, focus, battery

    var title: String {
        switch self {
        case .system: tr("系统")
        case .ai: tr("AI 用量")
        case .focus: tr("休息")
        case .battery: tr("电池")
        }
    }

    var symbol: String {
        switch self {
        case .system: "waveform.path.ecg"
        case .ai: "sparkles"
        case .focus: "timer"
        case .battery: "battery.100percent"
        }
    }

    var tint: Color {
        switch self {
        case .system: .mint
        case .ai: .purple
        case .focus: .orange
        case .battery: .green
        }
    }
}

/// 仅管理窗口展示；读数、账号和计时均由应用现有服务持有。
@MainActor @Observable
final class IslandModel {
    var presentation: IslandPresentation = .collapsed
    var scene: IslandScene = .system
    var date = Date()
    var powerNotice: IslandPowerNotice?
}

@MainActor
struct IslandReading {
    let scene: IslandScene
    let appModel: AppModel
    var now = Date()

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
            guard let metric = appModel.islandPreferences.primaryMetric else { return "—" }
            return metric.title + " " + value(for: metric)
        case .ai:
            return quotaSummary(at: now)
        case .battery: return batteryValue
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
    private var preferences: IslandPreferences { appModel.islandPreferences }
    private var reading: IslandReading { IslandReading(scene: model.scene, appModel: appModel, now: model.date) }
    var cpuValue: String { reading.cpuValue }
    var tokenValue: String { reading.tokenValue }
    var compactValue: String { reading.compactValue }

    var body: some View {
        Group {
            switch model.presentation {
            case .collapsed:
                Button(action: expand) {
                    HStack(spacing: IslandCompactLayout.spacing) {
                        if let notice = model.powerNotice {
                            Image(systemName: notice.symbol).foregroundStyle(notice == .lowBattery ? .orange : .green)
                                .frame(width: IslandCompactLayout.iconWidth)
                        } else if model.scene == .ai, let account = reading.quotaAccount,
                                  let window = account.primary(at: model.date), let remaining = window.remaining {
                            ZStack {
                                Circle().stroke(.white.opacity(0.2), lineWidth: 2)
                                Circle().trim(from: 0, to: min(1, max(0, settings.aiQuotaShowsRemaining ? remaining / 100 : 1 - remaining / 100)))
                                    .stroke(account.stale ? .orange : .purple, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                if account.stale { Image(systemName: "clock.fill").font(.system(size: 8)).foregroundStyle(.orange) }
                            }
                            .frame(width: IslandCompactLayout.iconWidth, height: IslandCompactLayout.iconWidth)
                            .accessibilityHidden(true)
                        } else {
                            Image(systemName: model.scene == .ai && reading.quotaAccount?.stale == true ? "clock.badge.exclamationmark" : reading.symbol)
                                .foregroundStyle(model.scene.tint).frame(width: IslandCompactLayout.iconWidth)
                        }
                        Text(model.powerNotice.map { $0.title + " " + reading.batteryValue } ?? compactValue).monospacedDigit().fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .frame(width: IslandCompactLayout.disclosureWidth)
                    }
                    .padding(.horizontal, IslandCompactLayout.horizontalPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(tr("展开灵动岛"))
                .accessibilityValue(model.powerNotice.map { $0.title + " " + reading.batteryValue } ?? (compactValue + " · " + reading.context))
            case .preview:
                Button(action: expand) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(model.scene.title, systemImage: reading.symbol).foregroundStyle(model.scene.tint)
                            Spacer()
                            Text("XStats").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(compactValue).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Spacer()
                            Text(tr("点击展开")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(reading.context).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
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
                    appModel.openMainWindow(model.scene == .system ? .overview : model.scene == .ai ? .aiUsage : model.scene == .battery ? .battery : .rest)
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
                    if let primary = preferences.primaryMetric {
                        Text(reading.value(for: primary)).font(.system(size: 34, weight: .semibold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(primary.title).foregroundStyle(.secondary)
                    }
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
            aiContent(at: model.date)
        case .battery:
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(reading.batteryValue).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Spacer()
                    Image(systemName: appModel.store.battery?.isCharging == true ? "battery.100percent.bolt" : "battery.100percent")
                        .font(.system(size: 30)).foregroundStyle(.green).accessibilityHidden(true)
                }
                if let battery = appModel.store.battery {
                    ProgressView(value: min(1, max(0, battery.level))).tint(.green)
                        .accessibilityLabel(tr("电池")).accessibilityValue(reading.batteryValue)
                    Text(reading.batteryContext).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let health = battery.health {
                        metric(tr("健康度"), value: health.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                    }
                } else {
                    Text(tr("暂无电池数据")).foregroundStyle(.secondary)
                    Text(tr("未检测到内置电池，或暂时无法读取。")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
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

    func aiContent(at date: Date) -> some View {
        @Bindable var settings = appModel.settings
        let accounts = reading.quotaAccounts
        let account = reading.quotaAccount
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !settings.aiUsageEnabled { Text(tr("尚未启用")).foregroundStyle(.secondary) }
                else {
                    Picker(tr("主显示账号"), selection: $settings.islandPreferences.quotaAccountID) {
                        Text(tr("自动选择账号")).tag("")
                        ForEach(accounts, content: IslandAccountOption.option)
                        if !settings.islandPreferences.quotaAccountID.isEmpty,
                           !accounts.contains(where: { $0.id == settings.islandPreferences.quotaAccountID }) {
                            Text(tr("所选账号不可用")).tag(settings.islandPreferences.quotaAccountID)
                        }
                    }
                    .font(.system(size: 11))
                    if let account {
                        if let primary = account.primary(at: date) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(reading.quotaValue(primary)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text(tr(settings.aiQuotaShowsRemaining ? "剩余" : "已用") + " · " + primary.title)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        MainActorForEach(account.windows.filter { $0.isCurrent(at: date) }) { window in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(window.title)
                                    Spacer()
                                    Text(reading.quotaValue(window)).monospacedDigit()
                                }
                                if let remaining = window.remaining, remaining.isFinite, !window.unlimited {
                                    ProgressView(value: min(100, max(0, settings.aiQuotaShowsRemaining ? remaining : 100 - remaining)), total: 100)
                                        .tint(.purple).accessibilityLabel(window.title)
                                        .overlay {
                                            if !account.stale, let fraction = window.paceFraction(at: date, showsRemaining: settings.aiQuotaShowsRemaining) {
                                                GeometryReader { geometry in
                                                    let position = settings.language.resolved.isRightToLeft ? 1 - fraction : fraction
                                                    Rectangle().fill(.white.opacity(0.9)).frame(width: 2, height: 10)
                                                        .position(x: 1 + max(0, geometry.size.width - 2) * position, y: geometry.size.height / 2)
                                                }
                                                .accessibilityHidden(true)
                                            }
                                        }
                                }
                                Text(window.resetsAt.map { tr("重置于：\($0.formatted(.dateTime.month(.defaultDigits).day().hour().minute().locale(L10n.locale)))") } ?? tr("重置时间未知"))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        if !account.stale, account.windows.contains(where: { $0.paceFraction(at: date, showsRemaining: settings.aiQuotaShowsRemaining) != nil }) {
                            Text(tr("刻线表示周期时间进度")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if account.windows.filter({ $0.isCurrent(at: date) }).isEmpty { Text(tr("暂无当前额度")).foregroundStyle(.secondary) }
                        if let status = account.status { Text(status).foregroundStyle(.orange) }
                        if account.stale { Text(tr("显示上次成功读取的数据。")).foregroundStyle(.orange) }
                        if let updated = account.updatedAt {
                            Text(updated, format: Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(settings.islandPreferences.quotaAccountID.isEmpty ? reading.quotaServiceStatus ?? tr("暂无额度数据") : tr("所选账号不可用"))
                            .foregroundStyle(.secondary)
                    }
                    if account == nil, !settings.islandPreferences.quotaAccountID.isEmpty,
                       let status = reading.quotaServiceStatus { Text(status).foregroundStyle(.orange) }
                    if settings.aiUsageShowsLocalUsage {
                        Divider()
                        HStack {
                            Text(tr("今日消耗的 Token")).foregroundStyle(.secondary)
                            Spacer()
                            Text(tokenValue).monospacedDigit()
                        }
                        if appModel.aiUsage.usesMagpie ? appModel.aiUsage.magpieUsageFailures[.daily] != nil : appModel.aiUsage.localState(for: nil).stale {
                            Text(tr("显示上次成功读取的数据。")).foregroundStyle(.orange)
                        }
                        if let updated = appModel.aiUsage.usesMagpie ? appModel.aiUsage.magpieUsageUpdatedAt[.daily] : appModel.aiUsage.localState(for: nil).updated {
                            Text(updated, format: Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// tag 保留在 Picker 的直接选项上；文字在 MainActor body 读取，兼容后台列表构建。
private struct IslandAccountOption: View {
    let account: IslandQuotaAccount
    nonisolated init(account: IslandQuotaAccount) { self.account = account }
    @Sendable nonisolated static func option(_ account: IslandQuotaAccount) -> some View {
        Self(account: account).tag(account.id)
    }
    var body: some View { Text(account.title) }
}
