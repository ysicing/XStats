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
        Binding(get: { currentProvider }, set: { selectedProvider = $0 })
    }

    private var providerPicker: some View {
        Picker(tr("订阅额度"), selection: selection) {
            ForEach(providers, id: \.self) { provider in
                Text(Self.title(provider)).tag(provider)
            }
        }
        .labelsHidden()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            if providers.count > 1 {
                // 服务较多或名称较长时使用原生菜单，避免压缩或截断 Tab。
                ViewThatFits(in: .horizontal) {
                    providerPicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                    providerPicker.pickerStyle(.menu)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(Self.title(currentProvider)).dsFont(.sm, weight: .semibold)
            }
            let visibleAccounts = accounts.filter { $0.provider == currentProvider }
            ForEach(Array(visibleAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.name).dsFont(.sm, weight: .semibold)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DS.Space.s2)
                        if let plan = account.plan { Text(plan).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary) }
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
                }
            }
        }
        .onChange(of: providers) { _, updated in
            if !updated.contains(selectedProvider) { selectedProvider = updated.first ?? "" }
        }
    }

    private func progressTint(for remaining: Double) -> Color {
        if remaining <= 10 { return DS.Palette.critical }
        if remaining <= 20 { return DS.Palette.error }
        if remaining < 40 { return DS.Palette.warning }
        if remaining < 80 { return DS.Palette.primary }
        return DS.Palette.success
    }

    private static func title(_ provider: String) -> String {
        switch provider {
        case "codex": "Codex"
        case "claude": "Claude"
        case "grok": "Grok"
        case "copilot": "GitHub Copilot"
        case "gemini": "Gemini"
        case "perplexity": "Perplexity"
        default: provider
        }
    }
}
