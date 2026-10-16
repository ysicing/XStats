// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import CryptoKit
import Foundation
import Localization
import Metrics

/// 一个账号的额度保持独立；只在该账号内部比较窗口，绝不跨账号累加。
struct IslandQuotaAccount: Identifiable, Sendable {
    struct Window: Identifiable, Sendable {
        let id: String
        let title: String
        let remaining: Double?
        let resetsAt: Date?
        var unlimited = false
        var duration: TimeInterval? = nil

        /// 刻线表示周期的时间进度；缺少可靠周期、周期外或陈旧数据时不推测。
        func paceFraction(at date: Date, showsRemaining: Bool) -> Double? {
            guard !unlimited, let remaining, remaining.isFinite,
                  let duration, duration.isFinite, duration > 0, let resetsAt else { return nil }
            let seconds = resetsAt.timeIntervalSince(date)
            guard seconds > 0, seconds <= duration else { return nil }
            let fraction = seconds / duration
            return showsRemaining ? fraction : 1 - fraction
        }

        func isCurrent(at date: Date) -> Bool {
            resetsAt.map { $0 > date } ?? true
        }
    }

    let id: String
    let title: String
    let windows: [Window]
    let updatedAt: Date?
    let stale: Bool
    let status: String?
    var compactTitle: String? = nil

    func primary(at date: Date) -> Window? {
        // 无限额度与未知数值不能参与紧张程度排序，过期窗口不能冒充当前额度。
        windows.filter { $0.isCurrent(at: date) && !$0.unlimited && $0.remaining?.isFinite == true }
            .min { $0.remaining! < $1.remaining! }
    }

    func displayWindow(at date: Date) -> Window? {
        primary(at: date) ?? windows.first(where: { $0.isCurrent(at: date) && $0.unlimited })
            ?? windows.first(where: { $0.isCurrent(at: date) })
    }

    static func selected(in accounts: [Self], id: String, at date: Date = Date()) -> Self? {
        guard id.isEmpty else { return accounts.first { $0.id == id } }
        // 自动选择优先可用的新鲜额度；固定账号不会因失败或消失偷偷切到另一个账号。
        return accounts.first { !$0.stale && $0.displayWindow(at: date) != nil }
            ?? accounts.first { $0.displayWindow(at: date) != nil }
            ?? accounts.first
    }

    /// 偏好中只保存不可逆身份摘要，不写入账号或邮箱原文。
    static func identity(_ value: String) -> String {
        // 每次视图读取都会使用此标识；直接编码十六进制，避免逐字节调用 Foundation 格式化。
        let hex = Array("0123456789abcdef".utf8)
        let digest = SHA256.hash(data: Data(value.utf8))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            bytes.append(hex[Int(byte >> 4)])
            bytes.append(hex[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@MainActor
extension IslandReading {
    var quotaAccounts: [IslandQuotaAccount] {
        let usage = appModel.aiUsage
        guard appModel.settings.aiUsageEnabled else { return [] }
        if usage.usesMagpie {
            let accounts = usage.magpieQuotas
            let names = Dictionary(grouping: accounts, by: { [$0.provider, $0.name] })
            return accounts.enumerated().map { index, account in
                let duplicate = (names[[account.provider, account.name]]?.count ?? 0) > 1
                let name = account.name.isEmpty ? account.provider : account.name
                let title = duplicate ? name + " · " + (account.user ?? String(index + 1)) : name
                return IslandQuotaAccount(id: IslandQuotaAccount.identity(account.id),
                    title: title,
                    windows: account.windows.enumerated().map { index, window in
                        .init(id: String(index), title: window.name, remaining: window.remaining,
                              resetsAt: window.resetsAt, unlimited: window.unlimited == true)
                    }, updatedAt: account.readAt ?? usage.magpieQuotaUpdatedAt,
                    stale: usage.magpieQuotaFailure != nil || account.error != nil,
                    status: account.error != nil || usage.magpieQuotaFailure != nil ? tr("暂时无法连接额度服务") : nil,
                    compactTitle: account.provider)
            }
        }
        return AIProviderID.allCases.filter { appModel.settings.aiUsageSources.contains($0) }.map { provider in
            let state = usage.visibleQuotaState(for: provider)
            let status: String?
            switch state.failure {
            case nil: status = state.isRefreshing && state.snapshot == nil ? tr("正在刷新") : nil
            case .notConfigured: status = tr("未检测到登录凭据，请先登录对应 CLI")
            case .unauthorized: status = tr("登录已失效，请在对应 CLI 重新登录")
            case .rateLimited: status = tr("服务暂时限流，稍后会自动重试")
            case .network: status = tr("暂时无法连接额度服务")
            case .invalidResponse: status = tr("额度接口返回了无法识别的数据")
            }
            return IslandQuotaAccount(id: provider.rawValue, title: provider == .codex ? "Codex" : "Claude Code",
                windows: state.snapshot?.windows.map { window in
                    .init(id: window.kind.rawValue, title: Self.quotaTitle(window.kind),
                          remaining: window.remainingPercent, resetsAt: window.resetsAt,
                          duration: window.duration)
                } ?? [], updatedAt: state.snapshot?.fetchedAt, stale: state.isStale || state.failure != nil, status: status)
        }
    }

    var quotaServiceStatus: String? {
        guard appModel.aiUsage.usesMagpie else { return nil }
        switch appModel.aiUsage.magpieQuotaFailure {
        case nil: return appModel.aiUsage.magpieRefreshing && appModel.aiUsage.magpieQuotas.isEmpty ? tr("正在刷新") : nil
        case .unavailable: return tr("暂时无法连接额度服务")
        case .invalidResponse, .responseTooLarge: return tr("额度接口返回了无法识别的数据")
        }
    }

    var quotaAccount: IslandQuotaAccount? {
        IslandQuotaAccount.selected(in: quotaAccounts, id: appModel.settings.islandPreferences.quotaAccountID, at: now)
    }

    static func quotaTitle(_ kind: AIQuotaKind) -> String {
        switch kind {
        case .session: tr("5 小时")
        case .weekly: tr("7 天")
        case .opusWeekly: "Opus · " + tr("7 天")
        case .sonnetWeekly: "Sonnet · " + tr("7 天")
        }
    }

    func quotaValue(_ window: IslandQuotaAccount.Window) -> String {
        if window.unlimited { return tr("无限额度") }
        guard let remaining = window.remaining, remaining.isFinite else { return "—" }
        return AIUsageFormat.quotaPercent(remainingPercent: remaining,
            showsRemaining: appModel.settings.aiQuotaShowsRemaining, locale: L10n.locale)
    }

    func quotaSummary(at date: Date) -> String {
        guard appModel.settings.aiUsageEnabled else { return tr("尚未启用") }
        guard let account = quotaAccount else {
            return appModel.settings.islandPreferences.quotaAccountID.isEmpty ? quotaServiceStatus ?? tr("暂无额度数据") : tr("所选账号不可用")
        }
        guard let window = account.displayWindow(at: date) else {
            return account.status ?? tr("暂无当前额度")
        }
        // 周期与账号详情放在悬停层；收起态的陈旧读数由时钟标记与辅助功能说明区分。
        return (account.compactTitle ?? account.title) + " " + quotaValue(window)
    }

    var symbol: String {
        guard scene == .battery else { return scene.symbol }
        if appModel.store.battery?.isCharging == true { return "battery.100percent.bolt" }
        if appModel.store.battery?.isPluggedIn == true { return "powerplug.fill" }
        return scene.symbol
    }

    var batteryValue: String {
        guard let battery = appModel.store.battery else { return "—" }
        return battery.level.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
    }

    var batteryContext: String {
        guard let battery = appModel.store.battery else { return tr("暂无电池数据") }
        guard let minutes = battery.minutesRemaining, minutes > 0,
              battery.isCharging || !battery.isPluggedIn else { return battery.stateText }
        let duration = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(L10n.locale))
        return battery.stateText + " · " + (battery.isCharging ? tr("预计充满：\(duration)") : tr("预计剩余：\(duration)"))
    }

    var context: String {
        switch scene {
        case .system: return appModel.islandPreferences.primaryMetric?.title ?? "—"
        case .ai:
            guard appModel.settings.aiUsageEnabled else { return tr("尚未启用") }
            guard let account = quotaAccount else { return quotaServiceStatus ?? tr("选择主显示账号") }
            guard let window = account.displayWindow(at: now) else { return account.status ?? tr("暂无当前额度") }
            let details = [account.stale ? tr("上次读取") : nil, account.title, window.title,
                tr(appModel.settings.aiQuotaShowsRemaining ? "剩余" : "已用"),
                window.resetsAt.map { tr("重置于：\($0.formatted(.dateTime.month(.defaultDigits).day().hour().minute().locale(L10n.locale)))") } ?? tr("重置时间未知"), account.status]
            return details.compactMap { $0 }.joined(separator: " · ")
        case .battery: return batteryContext
        case .focus: return appModel.settings.restEnabled ? appModel.rest.phase.title : tr("尚未启用")
        }
    }
}

/// 自动关注只影响收起态；展开后保持用户正在阅读的场景。陈旧额度不能触发告警抢占。
enum IslandFocus {
    static func scene(preferences: IslandPreferences, battery: BatteryStatus?, quota: IslandQuotaAccount?, at date: Date) -> IslandScene {
        guard preferences.automaticFocus else { return preferences.scene }
        if preferences.scenes.contains(.battery), let battery, !battery.isPluggedIn, battery.level <= 0.1 {
            return .battery
        }
        if preferences.scenes.contains(.ai), let quota, !quota.stale,
           let remaining = quota.primary(at: date)?.remaining, remaining <= 0 { return .ai }
        return preferences.scene
    }
}

/// 只比较可见期间相邻的真实读数；首次读取和恢复显示不补播历史事件。
enum IslandPowerNotice: Sendable, Equatable {
    case connected, disconnected, lowBattery, fullyCharged

    static func event(previous: BatteryStatus?, current: BatteryStatus) -> Self? {
        guard let previous else { return nil }
        if current.isPluggedIn != previous.isPluggedIn { return current.isPluggedIn ? .connected : .disconnected }
        if current.isPluggedIn, current.isFullyCharged, !previous.isFullyCharged { return .fullyCharged }
        if !current.isPluggedIn, current.level <= 0.2, previous.level > 0.2 { return .lowBattery }
        return nil
    }

    var title: String {
        switch self {
        case .connected: tr("已接通电源")
        case .disconnected: tr("已断开电源")
        case .lowBattery: tr("电池电量低")
        case .fullyCharged: tr("电池已充满")
        }
    }
    var symbol: String {
        switch self {
        case .connected: "powerplug.fill"
        case .disconnected: "powerplug.slash.fill"
        case .lowBattery: "battery.25percent"
        case .fullyCharged: "battery.100percent"
        }
    }
}
