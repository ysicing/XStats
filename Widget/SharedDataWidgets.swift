// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI
import WidgetData
import WidgetKit

struct SharedDataEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SharedDataProvider: TimelineProvider {
    func placeholder(in context: Context) -> SharedDataEntry {
        let now = Date()
        return SharedDataEntry(date: now, snapshot: WidgetSnapshot(
            aiEnabled: true,
            quotas: [.init(provider: "codex", kind: "weekly", remainingPercent: 68,
                           resetsAt: now.addingTimeInterval(2 * 24 * 3600), fetchedAt: now, isStale: false)],
            dailyTokens: [.init(provider: "codex", day: now, tokens: 28_400),
                          .init(provider: "claude", day: now, tokens: 12_600)],
            publicIPEnabled: true,
            addresses: [.init(family: "v4", ip: "203.0.113.8", countryCode: "CN", city: "上海",
                              organization: "Example Network", purityScore: 85, purityGrade: "A",
                              region: "上海", cityEnglish: "Shanghai", regionEnglish: "Shanghai",
                              asn: "AS4134", isNative: true, ipType: "Residential IP", riskFlags: [])]))
    }

    func getSnapshot(in context: Context, completion: @escaping (SharedDataEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SharedDataEntry>) -> Void) {
        let entry = read()
        // 不发起网络请求；到期额度须及时隐藏，主应用写入新缓存时也会主动要求重载。
        let nextReset = entry.snapshot.currentQuotas(at: entry.date)
            .compactMap(\.resetsAt).min().map { $0.addingTimeInterval(1) }
        let periodic = entry.date.addingTimeInterval(15 * 60)
        let nextMidnight = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: entry.date)?.end
        completion(Timeline(entries: [entry], policy: .after(min(nextReset ?? periodic, periodic, nextMidnight ?? periodic))))
    }

    private func read() -> SharedDataEntry {
        let snapshot = WidgetSnapshotStore().load()
        L10n.configure(AppLanguage(rawValue: snapshot.language) ?? .system)
        return SharedDataEntry(date: .now, snapshot: snapshot)
    }
}

private struct WidgetHeading: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct WidgetEmptyState: View {
    let enabled: Bool

    var body: some View {
        Text(enabled ? tr("暂无数据") : tr("尚未启用"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AIQuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SharedDataEntry

    private var featured: [WidgetSnapshot.Quota] {
        ["codex", "claude"].compactMap { provider in
            let windows = entry.snapshot.currentQuotas(at: entry.date).filter { $0.provider == provider }
            return windows.first(where: { $0.kind == "weekly" })
                ?? windows.first(where: { $0.kind.hasSuffix("Weekly") })
                ?? windows.first(where: { $0.kind == "session" })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeading(title: tr("订阅额度"), symbol: "sparkles")
            if let first = featured.first {
                if family == .systemMedium {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(featured, id: \.provider) { quota in
                            quotaColumn(quota)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    quotaColumn(first)
                }
            } else {
                WidgetEmptyState(enabled: entry.snapshot.aiEnabled)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .containerBackground(.background, for: .widget)
        .environment(\.locale, L10n.locale)
    }

    private func quotaColumn(_ quota: WidgetSnapshot.Quota) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(quota.provider == "codex" ? "Codex" : "Claude")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(quota.remainingPercent.rounded()))%")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(tr("剩余"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: quota.remainingPercent, total: 100)
                .tint(quota.remainingPercent < 20 ? .red : .blue)
            if let reset = quota.resetsAt {
                Text(tr("重置：") + " " + reset.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if quota.isStale {
                Text(tr("上次额度"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AIQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.aiQuota, provider: SharedDataProvider()) { entry in
            AIQuotaWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("订阅额度"))
        .description(tr("查看 Codex 和 Claude 的剩余额度与重置时间"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct TodayTokensWidgetView: View {
    let entry: SharedDataEntry

    private var sources: [(name: String, tokens: Int)] {
        ["codex", "claude"].compactMap { provider in
            guard let tokens = entry.snapshot.todayTokens(for: provider, at: entry.date) else { return nil }
            return (provider == "codex" ? "Codex" : "Claude", tokens)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeading(title: tr("今日消耗的 Token"), symbol: "sparkles")
            if sources.isEmpty {
                WidgetEmptyState(enabled: entry.snapshot.aiEnabled)
            } else {
                let total = sources.reduce(0) { $0 + $1.tokens }
                Text(total.formatted(.number.notation(.compactName).locale(L10n.locale)))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(total.formatted(.number.locale(L10n.locale)) + " Tokens")
                Spacer(minLength: 0)
                ForEach(sources, id: \.name) { source in
                    HStack {
                        Text(source.name)
                        Spacer(minLength: 4)
                        Text(source.tokens.formatted(.number.notation(.compactName).locale(L10n.locale)))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .containerBackground(.background, for: .widget)
        .environment(\.locale, L10n.locale)
    }
}

struct TodayTokensWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.todayTokens, provider: SharedDataProvider()) { entry in
            TodayTokensWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("今日消耗的 Token"))
        .description(tr("查看今天 Codex 和 Claude 的 Token 用量"))
        .supportedFamilies([.systemSmall])
    }
}

private struct IPPurityWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SharedDataEntry

    private var addresses: [WidgetSnapshot.Address] {
        entry.snapshot.visibleAddresses.filter { $0.purityScore != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeading(title: tr("IP 纯净度"), symbol: "checkmark.shield")
            if let first = addresses.first {
                if family == .systemMedium {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(addresses, id: \.family) { address in
                            purityRow(address, compact: addresses.count > 1)
                        }
                    }
                } else {
                    purityColumn(first)
                }
            } else {
                WidgetEmptyState(enabled: entry.snapshot.publicIPEnabled)
            }
            Spacer(minLength: 0)
            Text("cleanip.io · " + tr("主应用缓存"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .containerBackground(.background, for: .widget)
        .environment(\.locale, L10n.locale)
    }

    private func purityRow(_ address: WidgetSnapshot.Address, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            score(for: address, compact: compact)
                .frame(width: 90, alignment: .leading)
            addressDetails(for: address, compact: compact)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func purityColumn(_ address: WidgetSnapshot.Address) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            score(for: address, compact: false)
            addressDetails(for: address, compact: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func score(for address: WidgetSnapshot.Address, compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(address.purityScore ?? 0)")
                .font(.system(size: compact ? 27 : 36, weight: .semibold, design: .rounded))
            Text(tr("分"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let grade = address.purityGrade {
                Text(grade).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private func addressDetails(for address: WidgetSnapshot.Address, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 5) {
            if compact {
                HStack(spacing: 5) {
                    Text(address.family == "v4" ? "IPv4" : "IPv6")
                        .foregroundStyle(.secondary)
                    Text(address.ip)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2)
            } else {
                Text(address.family == "v4" ? "IPv4" : "IPv6")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(address.ip)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.7)
            }
            let labels = ipWidgetTags(for: address)
            if !labels.isEmpty {
                Text(labels.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct IPPurityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.ipPurity, provider: SharedDataProvider()) { entry in
            IPPurityWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("IP 纯净度"))
        .description(tr("显示主应用已查询的公网 IP 纯净度"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct PublicIPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SharedDataEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeading(title: tr("公网 IP"), symbol: "globe")
            if let first = entry.snapshot.visibleAddresses.first {
                if family == .systemMedium {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(entry.snapshot.visibleAddresses, id: \.family) { address in addressColumn(address) }
                    }
                } else {
                    addressColumn(first)
                }
            } else {
                WidgetEmptyState(enabled: entry.snapshot.publicIPEnabled)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .containerBackground(.background, for: .widget)
        .environment(\.locale, L10n.locale)
    }

    private func addressColumn(_ address: WidgetSnapshot.Address) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(address.family == "v4" ? "IPv4" : "IPv6")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(address.ip)
                .font(.system(size: family == .systemMedium ? 15 : 18, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.7)
                .help(address.ip)
            if let location = location(for: address) {
                Text(location)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let asn = address.asn {
                Text(asn)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            let tags = ipWidgetTags(for: address)
            if !tags.isEmpty {
                Text(tags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func location(for address: WidgetSnapshot.Address) -> String? {
        var parts: [String] = []
        if let code = address.countryCode {
            parts.append(L10n.locale.localizedString(forRegionCode: code) ?? code)
        }
        let region = L10n.usesEnglishNames ? (address.regionEnglish ?? address.region) : address.region
        let city = L10n.usesEnglishNames ? (address.cityEnglish ?? address.city) : address.city
        for part in [region, city].compactMap({ $0 }) where part != parts.last { parts.append(part) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private func ipWidgetTags(for address: WidgetSnapshot.Address) -> [String] {
    if let flags = address.riskFlags, !flags.isEmpty {
        return Array(flags.prefix(2)).map { flag in
            switch flag {
            case "vpn": "VPN"
            case "proxy": tr("代理")
            case "residentialProxy": tr("住宅代理")
            case "tor": "Tor"
            case "relay": tr("中继")
            case "datacenter": tr("机房")
            case "hosting": tr("托管")
            case "abuser": tr("滥用记录")
            default: flag
            }
        }
    }
    var labels: [String] = []
    if let isNative = address.isNative { labels.append(tr(isNative ? "原生 IP" : "广播 IP")) }
    if let ipType = address.ipType {
        switch ipType.lowercased() {
        case "residential ip": labels.append(tr("住宅 IP"))
        case "datacenter ip", "hosting ip": labels.append(tr("机房 IP"))
        case "mobile ip": labels.append(tr("移动网络 IP"))
        case "business ip": labels.append(tr("企业 IP"))
        default: break
        }
    }
    if labels.isEmpty, address.riskFlags != nil { labels.append(tr("未检出")) }
    return labels
}

struct PublicIPWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.publicIP, provider: SharedDataProvider()) { entry in
            PublicIPWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("公网 IP"))
        .description(tr("查看公网 IP、归属地、ASN 和标记"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
