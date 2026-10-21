// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import Metrics
import SwiftUI

struct LocalIPQueryButton: View {
  @State private var presented = false

  var body: some View {
    MiniIconButton(systemName: "network", help: tr("本机 IP 查询")) { presented = true }
      .sheet(isPresented: $presented) {
        LocalIPQueryView().environment(\.isPopover, false)
      }
  }
}

struct LocalIPQueryView: View {
  var query: @Sendable (LocalIPQuery.Source) async -> PublicAddresses? = LocalIPQuery.fetch
  @Environment(\.dismiss) private var dismiss
  @State private var revision = 0
  @State private var hideIP = false
  @State private var hideDomestic = false
  @State private var hideInternational = false

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack {
        Text(tr("本机 IP 查询")).font(.title2.bold())
        Spacer()
        Button(tr("刷新"), systemImage: "arrow.clockwise") { revision += 1 }
        Button(tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text(tr("按需连接第三方服务，查看它们看到的公网出口。不同来源可能经过不同代理路线。"))
        .foregroundStyle(.secondary)
        .font(.callout)
      ScrollView {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Space.s3) {
          ForEach(LocalIPQuery.Source.allCases) { source in
            LocalIPSourceCard(
              source: source, revision: revision, hideIP: hideIP,
              hideDetails: source == .domestic ? hideDomestic : hideInternational, query: query)
          }
        }
      }
      HStack {
        Toggle(tr("隐藏 IP"), isOn: $hideIP)
        Toggle(tr("隐藏国内信息"), isOn: $hideDomestic)
        Toggle(tr("隐藏国际信息"), isOn: $hideInternational)
      }
      .toggleStyle(.switch)
      .controlSize(.small)
    }
    .padding(DS.Space.s4)
    .frame(width: 720, height: 580)
    .background(DS.Palette.background)
  }
}

private struct LocalIPSourceCard: View {
  let source: LocalIPQuery.Source
  let revision: Int
  let hideIP: Bool
  let hideDetails: Bool
  let query: @Sendable (LocalIPQuery.Source) async -> PublicAddresses?
  @State private var retry = 0
  @State private var loading = true
  @State private var result: PublicAddresses?

  private var title: String {
    switch source {
    case .ipv4: "IPv4 · CleanIP"
    case .ipv6: "IPv6 · CleanIP"
    case .domestic: "CleanIP · " + tr("国内")
    case .cloudflare: "Cloudflare"
    }
  }

  var body: some View {
    Card(padding: DS.Space.s3, spacing: DS.Space.s3) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button(tr("重试"), systemImage: "arrow.clockwise") {
          retry += 1
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain).help(tr("重试")).disabled(loading)
      }
      if loading {
        HStack {
          ProgressView().controlSize(.small)
          Text(tr("查询中…"))
        }
      } else if hideDetails {
        Text(tr("信息已隐藏")).foregroundStyle(.secondary)
      } else if let result, let ip = result.ipv4 ?? result.ipv6 {
        if hideIP {
          Text("••••••••").accessibilityLabel(tr("隐藏 IP"))
        } else {
          CopyableText(text: ip)
        }
        InfoRow(label: tr("归属地"), text: location(result))
        InfoRow(label: tr("网络运营方"), text: result.organization ?? "—")
        InfoRow(label: "ASN", text: result.asn ?? "—")
      } else {
        Text(tr("未获取到地址，请检查网络或稍后重试。"))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .frame(minHeight: 200)
    // SwiftUI 负责取消旧任务；取消后不发布结果，防止快速刷新覆盖新一轮状态。
    .task(id: "\(revision)-\(retry)") {
      loading = true
      result = nil
      let value = await query(source)
      guard !Task.isCancelled else { return }
      result = value
      loading = false
    }
  }

  private func location(_ value: PublicAddresses) -> String {
    let country = value.countryCode.flatMap { L10n.locale.localizedString(forRegionCode: $0) }
    let region = L10n.usesEnglishNames ? value.regionEnglish ?? value.region : value.region
    let city = L10n.usesEnglishNames ? value.cityEnglish ?? value.city : value.city
    var parts: [String] = []
    for part in [country, region, city].compactMap({ $0 }) where parts.last != part {
      parts.append(part)
    }
    return parts.isEmpty ? "—" : parts.joined(separator: " · ")
  }
}
