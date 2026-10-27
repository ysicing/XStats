// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI
import WidgetData
import WidgetKit

struct SharedDataEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot
  var hasSnapshot = true
  var showsResetRing: Bool { snapshot.quotaShowsResetRing == true }

  var quotaSlots: [WidgetSnapshot.QuotaSlot] {
    snapshot.quotaSlots(at: date)
  }
}

struct SharedDataProvider: TimelineProvider {
  var showsQuotaResetProgress = false
  func placeholder(in context: Context) -> SharedDataEntry {
    let now = Date()
    return SharedDataEntry(
      date: now,
      snapshot: WidgetSnapshot(
        aiEnabled: true,
        quotas: [
          .init(
            provider: "codex", kind: "weekly", remainingPercent: 68,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600), fetchedAt: now, isStale: false)
        ],
        dailyTokens: [
          .init(provider: "codex", day: now, tokens: 28_400),
          .init(provider: "claude", day: now, tokens: 12_600),
        ],
        cumulativeTokens: [
          .init(provider: "codex", input: 2_100_000, output: 410_000, scope: .recentYear),
          .init(provider: "claude", input: 720_000, output: 180_000, scope: .recentYear),
        ],
        quotaProviders: ["codex", "claude", "gemini", "grok"],
        publicIPEnabled: true,
        addresses: [
          .init(
            family: "v4", ip: "203.0.113.8", countryCode: "CN", city: "上海",
            organization: "Example Network", purityScore: 85, purityGrade: "A",
            region: "上海", cityEnglish: "Shanghai", regionEnglish: "Shanghai",
            asn: "AS4134", isNative: true, ipType: "Residential IP", riskFlags: [])
        ]))
  }

  func getSnapshot(in context: Context, completion: @escaping (SharedDataEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : read())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<SharedDataEntry>) -> Void) {
    completion(timeline(for: read()))
  }

  func timeline(for entry: SharedDataEntry) -> Timeline<SharedDataEntry> {
    // 不发起网络请求，也不周期轮询：数据变化时主应用会主动要求重载；
    // 这里只需在额度到期（须隐藏）和午夜换日（当日 Token 归零）时自行刷新。
    let quotas =
      showsQuotaResetProgress
      ? entry.quotaSlots.compactMap(\.quota) : entry.snapshot.currentQuotas(at: entry.date)
    let nextReset =
      quotas
      .compactMap(\.resetsAt).min().map { $0.addingTimeInterval(1) }
    let nextMidnight = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: entry.date)?.end
    let next = [nextReset, nextMidnight].compactMap { $0 }.min()
    // 周倒计时使用预先生成的小时条目，不增加接口请求或后台定时器。
    var entries = [entry]
    if showsQuotaResetProgress,
      entry.quotaSlots.contains(where: {
        $0.quota?.resetsAt != nil
      }), let next
    {
      for hour in 1...24 {
        let date = entry.date.addingTimeInterval(Double(hour) * 3600)
        guard date < next else { break }
        entries.append(
          SharedDataEntry(
            date: date, snapshot: entry.snapshot, hasSnapshot: entry.hasSnapshot))
      }
    }
    return Timeline(entries: entries, policy: next.map { .after($0) } ?? .never)
  }

  func read() -> SharedDataEntry {
    let snapshot = WidgetSnapshotStore().loadIfAvailable()
    L10n.configure(AppLanguage(rawValue: snapshot?.language ?? "system") ?? .system)
    return SharedDataEntry(
      date: .now, snapshot: snapshot ?? WidgetSnapshot(), hasSnapshot: snapshot != nil)
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
  let hasSnapshot: Bool

  var body: some View {
    Text(tr(hasSnapshot ? (enabled ? "暂无数据" : "尚未启用") : "共享数据不可用"))
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private func aiWidgetProviderTitle(_ provider: String) -> String {
  AIServiceBrand.title(provider)
}

@MainActor
private enum AIWidgetLogos {
  // 仅按需缓存已打包的服务标志，同品牌不同地区复用资源，不访问网络或主程序目录。
  private static var images: [String: NSImage] = [:]

  static func image(for provider: String, dark: Bool) -> NSImage? {
    guard let name = AIServiceBrand.logoName(provider) else { return nil }
    let originalColors = AIServiceBrand.usesOriginalLogoColors(provider)
    let key = "\(name):\(originalColors && dark)"
    if let image = images[key] { return image }
    guard let url = Bundle.main.url(forResource: name, withExtension: "svg") else { return nil }
    let image: NSImage?
    if originalColors, let svg = try? String(contentsOf: url, encoding: .utf8) {
      // Kimi、Qoder 等彩色标志同时含前景色路径；仅替换 currentColor，保留品牌色与渐变。
      image = NSImage(
        data: Data(svg.replacingOccurrences(of: "currentColor", with: dark ? "#fff" : "#000").utf8))
    } else {
      image = NSImage(contentsOf: url)
    }
    guard let image else { return nil }
    image.isTemplate = !originalColors
    images[key] = image
    return image
  }
}

private struct AIQuotaRing: View {
  @Environment(\.colorScheme) private var colorScheme
  let slot: WidgetSnapshot.QuotaSlot
  let date: Date
  let showsResetRing: Bool

  private var color: Color {
    guard let remaining = slot.quota?.remainingPercent else { return .secondary }
    switch remaining {
    case ..<10: return .red
    case ..<20: return .orange
    case ..<50: return .blue
    default: return .green
    }
  }

  private var percent: String {
    slot.quota.map {
      AIUsageFormat.quotaPercent(
        remainingPercent: $0.remainingPercent, showsRemaining: true,
        locale: L10n.locale, compact: true)
    } ?? "—"
  }

  var body: some View {
    GeometryReader { geometry in
      let side = min(geometry.size.width, geometry.size.height)
      ZStack {
        Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 5)
        if let quota = slot.quota {
          Circle().inset(by: 2.5)
            .trim(from: 0, to: min(1, max(0, quota.remainingPercent / 100)))
            .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        if showsResetRing {
          Circle().strokeBorder(.primary.opacity(0.06), lineWidth: 3).padding(9)
          if let fraction = slot.quota?.weeklyResetFraction(at: date) {
            Circle().inset(by: 10.5)
              .trim(from: 0, to: fraction)
              .stroke(.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
              .rotationEffect(.degrees(-90))
          }
        }
        if let logo = AIWidgetLogos.image(for: slot.provider, dark: colorScheme == .dark) {
          Image(nsImage: logo).resizable().scaledToFit()
            .frame(
              width: side * (showsResetRing ? 0.32 : 0.44),
              height: side * (showsResetRing ? 0.32 : 0.44)
            )
            .foregroundStyle(
              Color(nsColor: AIServiceBrand.dotColor(slot.provider, foreground: .labelColor)))
        } else {
          // 尚无品牌资源的服务保留可辨识名称，不以其他服务的标志冒充。
          Text(aiWidgetProviderTitle(slot.provider))
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.5).padding(17)
        }
      }
      .foregroundStyle(slot.quota == nil ? Color.secondary : Color.primary)
      .opacity(slot.quota?.isStale == true ? 0.55 : 1)
      .frame(width: side, height: side)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(aiWidgetProviderTitle(slot.provider))
    .accessibilityValue(accessibilityValue)
    .help(aiWidgetProviderTitle(slot.provider) + ": " + accessibilityValue)
  }

  private var accessibilityValue: String {
    guard let quota = slot.quota else { return tr("暂无额度数据") }
    var value = tr("剩余") + " " + percent
    if quota.isStale { value += ", " + tr("上次额度") }
    if let reset = quota.resetsAt {
      value +=
        ", " + tr("重置：") + " "
        + reset.formatted(
          .dateTime.month().day().hour().minute().locale(L10n.locale))
    }
    return value
  }
}

private struct AIQuotaWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: SharedDataEntry

  private var language: AppLanguage {
    AppLanguage(rawValue: entry.snapshot.language) ?? .system
  }

  var body: some View {
    let slots = entry.quotaSlots
    VStack(alignment: .leading, spacing: 6) {
      if !entry.hasSnapshot || !entry.snapshot.aiEnabled {
        WidgetHeading(title: tr("订阅额度"), symbol: "sparkles")
        WidgetEmptyState(enabled: entry.snapshot.aiEnabled, hasSnapshot: entry.hasSnapshot)
      } else if family == .systemSmall {
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
          ForEach(0..<2) { row in
            GridRow {
              ForEach(Array(slots[(row * 2)..<(row * 2 + 2)])) { slot in
                quotaCell(slot)
              }
            }
          }
        }
      } else {
        HStack {
          WidgetHeading(title: tr("订阅额度"), symbol: "sparkles")
          Spacer(minLength: 4)
          Text(tr("剩余"))
            .font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        HStack(alignment: .top, spacing: 12) {
          ForEach(slots) { slot in quotaCell(slot) }
        }
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .containerBackground(.background, for: .widget)
    .environment(\.locale, L10n.locale(for: language))
  }

  private func quotaCell(_ slot: WidgetSnapshot.QuotaSlot) -> some View {
    VStack(spacing: family == .systemSmall ? 3 : 6) {
      AIQuotaRing(slot: slot, date: entry.date, showsResetRing: entry.showsResetRing)
      Text(
        AIUsageFormat.quotaReset(
          at: slot.quota?.resetsAt, relativeTo: entry.date, language: language)
      )
      .font(.system(size: family == .systemSmall ? 9 : 10))
      .foregroundStyle(.secondary)
      .lineLimit(1).minimumScaleFactor(0.7)
      .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity)
  }
}

struct AIQuotaWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: WidgetKind.aiQuota, provider: SharedDataProvider(showsQuotaResetProgress: true)
    ) { entry in
      AIQuotaWidgetView(entry: entry)
    }
    .configurationDisplayName(tr("订阅额度"))
    .description(tr("以四个圆环查看订阅额度"))
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

private struct TodayTokensWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: SharedDataEntry

  private func formatted(_ count: Int) -> String {
    AIUsageFormat.tokens(
      count, westernUnits: entry.snapshot.westernUnits == true, locale: L10n.locale)
  }

  var body: some View {
    let sources = entry.snapshot.visibleCumulativeTokens
    let total = WidgetSnapshot.TokenUsage.sum(sources.map(\.total))
    VStack(alignment: .leading, spacing: 6) {
      WidgetHeading(title: tr("累计 Token"), symbol: "sparkles")
      if sources.isEmpty {
        WidgetEmptyState(enabled: entry.snapshot.showsLocalUsage, hasSnapshot: entry.hasSnapshot)
      } else {
        HStack(alignment: .top, spacing: 20) {
          VStack(alignment: .leading, spacing: 3) {
            Text(formatted(total))
              .font(.system(size: 32, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .lineLimit(1)
              .minimumScaleFactor(0.6)
              .accessibilityLabel(total.formatted(.number.locale(L10n.locale)) + " Tokens")
            HStack(spacing: 3) {
              if sources.contains(where: \.isStale) {
                Image(systemName: "clock").accessibilityLabel(tr("上次数据"))
              }
              Text(tr(sources.allSatisfy { $0.scope == .all } ? "Magpie 全部记录" : "最近 365 天"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if family == .systemMedium {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(sources, id: \.provider) { source in
                HStack {
                  Text(aiWidgetProviderTitle(source.provider))
                  Spacer(minLength: 4)
                  Text(formatted(source.total)).monospacedDigit()
                }
                .font(.caption)
                .lineLimit(1)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        Spacer(minLength: 0)
        HStack(spacing: 12) {
          tokenColumn("输入", count: WidgetSnapshot.TokenUsage.sum(sources.map(\.input)))
          tokenColumn("输出", count: WidgetSnapshot.TokenUsage.sum(sources.map(\.output)))
        }
        if let daily = entry.snapshot.dailyTokens, !daily.isEmpty {
          let today = WidgetSnapshot.TokenUsage.sum(
            daily.compactMap {
              entry.snapshot.todayTokens(for: $0.provider, at: entry.date)
            })
          HStack {
            Text(tr("今日消耗的 Token"))
            Spacer(minLength: 4)
            Text(formatted(today)).monospacedDigit()
          }
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .containerBackground(.background, for: .widget)
    .environment(\.locale, L10n.locale)
  }

  private func tokenColumn(_ title: String, count: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(tr(title)).font(.system(size: 9)).foregroundStyle(.secondary)
      Text(formatted(count)).font(.caption.weight(.medium)).monospacedDigit()
    }
    .lineLimit(1)
    .minimumScaleFactor(0.7)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct TodayTokensWidget: Widget {
  var body: some WidgetConfiguration {
    // 保留旧 kind，已有桌面小组件无需重新添加。
    StaticConfiguration(kind: WidgetKind.todayTokens, provider: SharedDataProvider()) { entry in
      TodayTokensWidgetView(entry: entry)
    }
    .configurationDisplayName(tr("累计 Token"))
    .description(tr("查看累计 Token、输入输出与今日用量"))
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
          VStack(alignment: .leading, spacing: 8) {
            ForEach(addresses, id: \.family) { address in
              purityRow(address, compact: addresses.count > 1)
            }
          }
        } else {
          purityColumn(first)
        }
      } else {
        WidgetEmptyState(enabled: entry.snapshot.publicIPEnabled, hasSnapshot: entry.hasSnapshot)
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
            ForEach(entry.snapshot.visibleAddresses, id: \.family) { address in
              addressColumn(address)
            }
          }
        } else {
          addressColumn(first)
        }
      } else {
        WidgetEmptyState(enabled: entry.snapshot.publicIPEnabled, hasSnapshot: entry.hasSnapshot)
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
        .font(
          .system(size: family == .systemMedium ? 15 : 18, weight: .semibold, design: .monospaced)
        )
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
