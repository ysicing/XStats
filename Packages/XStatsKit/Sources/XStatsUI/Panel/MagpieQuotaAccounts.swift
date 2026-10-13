// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Localization
import SwiftUI

/// 服务选择仅过滤已读取的额度，不重新请求，也不将同服务的账户额度相加。
struct MagpieQuotaAccounts: View {
    let accounts: [MagpieQuota]
    @Environment(AppModel.self) private var model
    @State private var selectedProvider: String

    init(accounts: [MagpieQuota]) {
        self.accounts = accounts
        _selectedProvider = State(initialValue: accounts.first?.provider ?? "")
    }

    private var providers: [String] {
        var seen: Set<String> = []
        return accounts.compactMap { seen.insert($0.provider).inserted ? $0.provider : nil }
    }

    private var currentProvider: String {
        providers.contains(selectedProvider) ? selectedProvider : providers.first ?? ""
    }

    // 刷新可能移除已选服务；同一帧使用有效选项，避免 Picker 暂时持有不存在的标签。
    private var selection: Binding<String> {
        Binding(get: { currentProvider }, set: { provider in
            DS.Motion.select { selectedProvider = provider }
        })
    }

    private var providerPicker: some View {
        Picker(tr("订阅额度"), selection: selection) {
            ForEach(providers, id: \.self) { provider in
                providerLabel(provider).tag(provider)
            }
        }
        .labelsHidden()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            if providers.count > 1 {
                // 服务较多或名称较长时使用原生菜单，避免压缩或截断 Tab。
                ViewThatFits(in: .horizontal) {
                    MagpieProviderPicker(providers: providers, selection: selection)
                        .fixedSize(horizontal: true, vertical: false)
                    providerPicker.pickerStyle(.menu)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                providerLabel(currentProvider).dsFont(.sm, weight: .semibold)
            }
            // 只淡入新的账户组；旧组即时移除，快速切换时不叠加过期额度。
            // 内层取消隐式动画，避免进度条和数字在服务之间插值。
            ZStack(alignment: .topLeading) {
                accountContent.transaction { $0.animation = nil }
                    .id(currentProvider)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            .dsSelectionAnimation(DS.Motion.usageSelection, value: currentProvider)
        }
        .onChange(of: providers) { _, updated in
            if !updated.contains(selectedProvider) { selectedProvider = updated.first ?? "" }
        }
    }

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            let visibleAccounts = accounts.filter { $0.provider == currentProvider }
            ForEach(Array(visibleAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.name).dsFont(.sm, weight: .semibold)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DS.Space.s2)
                        if let plan = account.plan {
                            Text(plan).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if let user = account.user, !user.isEmpty {
                        Text(user).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                            .lineLimit(1).truncationMode(.middle).help(user).textSelection(.enabled)
                    }
                    if account.error != nil {
                        Text(tr("Magpie 未能读取此账户的额度。"))
                            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    } else {
                        ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                            HStack {
                                Text(window.name).foregroundStyle(DS.Palette.textSecondary)
                                Spacer(minLength: DS.Space.s2)
                                if window.unlimited == true { Text(tr("不限额")) }
                                else if let remaining = window.remaining,
                                        window.resetsAt.map({ $0 > Date() }) ?? true {
                                    Text(tr(model.settings.aiQuotaShowsRemaining ? "剩余" : "已用") + " "
                                        + (!model.settings.aiQuotaShowsRemaining && (window.used ?? 0) > 100
                                            ? ((window.used ?? 100) / 100).formatted(.percent.locale(L10n.locale))
                                            : AIUsageFormat.quotaPercent(remainingPercent: remaining,
                                            showsRemaining: model.settings.aiQuotaShowsRemaining, locale: L10n.locale)))
                                        .monospacedDigit()
                                } else { Text(window.display ?? "—") }
                            }.dsFont(.xs)
                            if window.unlimited != true, let remaining = window.remaining,
                               window.resetsAt.map({ $0 > Date() }) ?? true {
                                // 超额时条长最多填满，百分比文字仍保留服务端的真实值。
                                ProgressTrack(fraction: (AIUsageFormat.quotaValue(remainingPercent: remaining,
                                    showsRemaining: model.settings.aiQuotaShowsRemaining) ?? 0) / 100,
                                    color: progressTint(for: remaining))
                                    .accessibilityHidden(true) // 相邻文字已完整表达窗口与额度，避免重复朗读。
                            }
                            if let reset = window.resetsAt {
                                Text(tr("重置：") + " " + reset.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)))
                                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                            }
                        }
                        if let balance = account.balance { Text(balance).dsFont(.xs) }
                    }
                    MagpieAccountDetails(account: account)
                }
            }
        }
    }

    private func progressTint(for remaining: Double) -> Color {
        if remaining <= 10 { return DS.Palette.critical }
        if remaining <= 20 { return DS.Palette.error }
        if remaining < 40 { return DS.Palette.warning }
        if remaining < 80 { return DS.Palette.primary }
        return DS.Palette.success
    }

    private func providerLabel(_ provider: String) -> some View {
        Label {
            Text(AIServiceBrand.title(provider))
        } icon: {
            if let name = AIServiceBrand.logoName(provider),
               let logo = LogoCache.shared.image(named: name, template: true) {
                Image(nsImage: logo).resizable().scaledToFit().frame(width: 14, height: 14)
            } else {
                Image(systemName: "sparkles")
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

/// 低频账户信息放在额度下方；逐张有效期由原生披露控件按需展开，不增加刷新任务。
private struct MagpieAccountDetails: View {
    let account: MagpieQuota

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            if let until = account.until {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Label(tr("套餐有效期"), systemImage: "calendar")
                    Spacer(minLength: DS.Space.s1)
                    Text(UsageNumber.quotaDate(until, includesTime: true))
                        .multilineTextAlignment(.trailing)
                }
            }
            if let resets = account.resets, let count = resets.count {
                // 数量以 count 为准；逐张列表多于数量时只展示最早到期的 count 张，避免标题与明细不一致。
                let dates = Array((resets.each ?? []).compactMap(\.until).sorted().prefix(count))
                if count > 0, !dates.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: DS.Space.s1) {
                            ForEach(Array(dates.enumerated()), id: \.offset) { _, date in
                                Text(tr("到期：\(UsageNumber.quotaDate(date, includesTime: true))"))
                            }
                        }
                        // macOS 的披露内容默认靠尾端放置，铺满可用宽度使详情跟随摘要对齐。
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Space.s1)
                        .foregroundStyle(DS.Palette.textTertiary)
                    } label: {
                        resetSummary(count: count, until: dates.first ?? resets.until)
                    }
                } else {
                    resetSummary(count: count, until: count > 0 ? resets.until : nil)
                }
            }
        }
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    }

    private func resetSummary(count: Int, until: Date?) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Label(tr("重置卡：\(count.formatted(.number.locale(L10n.locale)))"), systemImage: "arrow.counterclockwise.circle")
            if let until {
                Text(tr("最早到期：\(UsageNumber.quotaDate(until, includesTime: true))"))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .help(tr("可手动恢复额度的剩余次数，不是已重置次数。"))
    }
}
