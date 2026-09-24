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
            publicIPEnabled: true,
            addresses: [.init(family: "v4", ip: "203.0.113.8", countryCode: "CN", city: nil,
                              organization: nil, purityScore: 85, purityGrade: "A")]))
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
        completion(Timeline(entries: [entry], policy: .after(min(nextReset ?? periodic, periodic))))
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
        StaticConfiguration(kind: "work.12306.xstats.widget.aiQuota", provider: SharedDataProvider()) { entry in
            AIQuotaWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("订阅额度"))
        .description(tr("查看 Codex 和 Claude 的剩余额度与重置时间"))
        .supportedFamilies([.systemSmall, .systemMedium])
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
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(addresses, id: \.family) { address in purityColumn(address) }
                        Spacer(minLength: 0)
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

    private func purityColumn(_ address: WidgetSnapshot.Address) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(address.purityScore ?? 0)")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                Text(tr("分"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let grade = address.purityGrade {
                    Text(grade).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            Text(address.family == "v4" ? "IPv4" : "IPv6")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(address.ip)
                .font(.caption.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IPPurityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "work.12306.xstats.widget.ipPurity", provider: SharedDataProvider()) { entry in
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
                    ForEach(entry.snapshot.visibleAddresses, id: \.family) { address in addressRow(address) }
                } else {
                    addressRow(first)
                }
            } else {
                WidgetEmptyState(enabled: entry.snapshot.publicIPEnabled)
            }
            Spacer(minLength: 0)
            Text(tr("主应用缓存"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .containerBackground(.background, for: .widget)
        .environment(\.locale, L10n.locale)
    }

    private func addressRow(_ address: WidgetSnapshot.Address) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(address.family == "v4" ? "IPv4" : "IPv6")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(address.ip)
                .font(.system(size: family == .systemMedium ? 18 : 17, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if let location = [address.countryCode, address.city].compactMap({ $0 }).first {
                Text(location).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct PublicIPWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "work.12306.xstats.widget.publicIP", provider: SharedDataProvider()) { entry in
            PublicIPWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("公网 IP"))
        .description(tr("显示主应用已查询的公网 IPv4 和 IPv6"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
