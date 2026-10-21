// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import Metrics
import SwiftUI

struct LocalIPQueryButton: View {
  @Environment(AppModel.self) private var model
  @State private var presented = false

  var body: some View {
    MiniIconButton(systemName: "network", help: tr("本机 IP 查询")) { presented = true }
      .sheet(isPresented: $presented) {
        LocalIPQueryView(openEgress: model.openEgressWindow).environment(\.isPopover, false)
      }
  }
}

struct LocalIPQueryView: View {
  var query: @Sendable (LocalIPQuery.Source) async -> LocalIPQuery.Response = LocalIPQuery.fetch
  var readInterfaces: @Sendable () async -> [LocalNetworkInterface] = {
    await Task.detached { NetworkDetailsReader.readLocalInterfaces() }.value
  }
  var openEgress: () -> Void = {}
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
        Button(tr("完成")) { dismiss() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      Text(tr("按需连接第三方服务，查看它们看到的公网出口。不同来源可能经过不同代理路线。"))
        .foregroundStyle(.secondary)
        .font(.callout)
      ScrollView {
        HStack(alignment: .top, spacing: DS.Space.s3) {
          VStack(spacing: DS.Space.s3) {
            Card(padding: DS.Space.s3, spacing: DS.Space.s3) {
              ForEach([LocalIPQuery.Source.ipv4, .ipv6]) { source in
                if source == .ipv6 { HairlineDivider() }
                LocalIPSourceView(
                  source: source, revision: revision, hideIP: hideIP,
                  hideDetails: hideInternational, query: query)
              }
            }
            .fixedSize(horizontal: false, vertical: true)
            LocalInterfacesView(revision: revision, hideIP: hideIP, read: readInterfaces)
          }
          .frame(width: 330)
          Card(padding: DS.Space.s3, spacing: DS.Space.s3) {
            Label(tr("出口对比"), systemImage: "point.3.connected.trianglepath.dotted")
              .font(.headline)
            ForEach([LocalIPQuery.Source.domestic, .cloudflare, .ipify]) { source in
              HairlineDivider()
              LocalIPSourceView(
                source: source, revision: revision, hideIP: hideIP,
                hideDetails: source == .domestic ? hideDomestic : hideInternational, query: query)
            }
          }
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      // 为查询结果保留稳定视口；长归属地可滚动，刷新和隐私切换不会反复改变弹窗尺寸。
      .frame(height: 410)
      HairlineDivider()
      HStack {
        Toggle(tr("隐藏 IP"), isOn: $hideIP)
        Toggle(tr("隐藏国内信息"), isOn: $hideDomestic)
        Toggle(tr("隐藏国际信息"), isOn: $hideInternational)
        Spacer()
        Button(tr("出口与分流"), systemImage: "arrow.triangle.branch") {
          dismiss()
          openEgress()
        }
        .buttonStyle(.bordered)
        .help(tr("查看网站连通性与代理路线"))
      }
      .toggleStyle(.switch)
      .controlSize(.small)
    }
    .padding(DS.Space.s4)
    .frame(width: 780, height: 560)
    .background(DS.Palette.background)
    .onExitCommand { dismiss() }
  }
}

private struct LocalInterfacesView: View {
  let revision: Int
  let hideIP: Bool
  let read: @Sendable () async -> [LocalNetworkInterface]
  @State private var interfaces: [LocalNetworkInterface]?

  var body: some View {
    Card(padding: DS.Space.s3, spacing: DS.Space.s3) {
      Label(tr("本地接口"), systemImage: "network").font(.headline)
      if let interfaces {
        if interfaces.isEmpty {
          Text(tr("暂无已连接的本地接口")).font(.callout).foregroundStyle(.secondary)
        }
        ForEach(interfaces) { interface in
          HairlineDivider()
          LocalInterfaceRow(interface: interface, hideIP: hideIP)
        }
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .task(id: revision) {
      let result = await read()
      guard !Task.isCancelled else { return }
      interfaces = result
    }
  }
}

/// 隐藏地址时不挂载复制按钮或展开内容，辅助功能与剪贴板入口也不会泄漏地址。
struct LocalInterfaceRow: View {
  let interface: LocalNetworkInterface
  let hideIP: Bool
  @State private var expanded = false

  private var title: String {
    if let name = interface.name, !name.isEmpty { return name }
    return switch interface.kind {
    case .wifi: "Wi-Fi"
    case .ethernet: tr("有线网络")
    case .tunnel: tr("VPN / 隧道")
    case .other: tr("其他接口")
    }
  }

  private var symbol: String {
    switch interface.kind {
    case .wifi: "wifi"
    case .ethernet: "cable.connector"
    case .tunnel: "network.badge.shield.half.filled"
    case .other: "network"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s2) {
      HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
        Label(title, systemImage: symbol).font(.callout.weight(.semibold))
        Spacer(minLength: 0)
        Text(verbatim: interface.bsdName).font(.caption).foregroundStyle(.secondary)
      }
      if hideIP {
        Text("••••••••").accessibilityLabel(tr("隐藏 IP"))
      } else {
        if let ipv4 = interface.ipv4.first { address(ipv4, family: "IPv4") }
        if let ipv6 = interface.ipv6.first { address(ipv6, family: "IPv6") }
        if interface.ipv4.count > 1 || interface.ipv6.count > 1 || !interface.linkLocal.isEmpty {
          DisclosureGroup(tr("更多地址"), isExpanded: $expanded) {
            ForEach(Array(interface.ipv4.dropFirst()), id: \.self) { address($0, family: "IPv4") }
            ForEach(Array(interface.ipv6.dropFirst()), id: \.self) { address($0, family: "IPv6") }
            ForEach(interface.linkLocal, id: \.self) {
              address($0, family: tr("链路本地"))
            }
          }
          .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func address(_ text: String, family: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
      Text(verbatim: family).font(.caption2).foregroundStyle(.secondary)
        .fixedSize()
      CopyableText(text: text)
        .font(.system(.callout, design: .monospaced))
        .help(text)
        .environment(\.layoutDirection, .leftToRight)
    }
  }
}

private struct LocalIPSourceView: View {
  let source: LocalIPQuery.Source
  let revision: Int
  let hideIP: Bool
  let hideDetails: Bool
  let query: @Sendable (LocalIPQuery.Source) async -> LocalIPQuery.Response
  @State private var retry = 0
  @State private var response: LocalIPQuery.Response?

  private var title: String {
    switch source {
    case .ipv4: "IPv4"
    case .ipv6: "IPv6"
    case .domestic: "CleanIP"
    case .cloudflare: "Cloudflare"
    case .ipify: "ipify"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s2) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        if source == .domestic || source == .cloudflare || source == .ipify {
          TagBadge(
            text: source == .domestic ? tr("国内") : tr("国际"),
            tone: source == .domestic ? .neutral : .primary)
        }
        Button(tr("重试"), systemImage: "arrow.clockwise") {
          retry += 1
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless).help(tr("重试")).disabled(response == nil)
      }
      LocalIPResultContent(
        source: source, response: response, hideIP: hideIP, hideDetails: hideDetails)
    }
    // SwiftUI 负责取消旧任务；取消后不发布结果，防止快速刷新覆盖新一轮状态。
    .task(id: "\(revision)-\(retry)") {
      response = nil
      let value = await query(source)
      guard !Task.isCancelled else { return }
      response = value
    }
  }
}

/// 隐私分支不挂载地址或详情视图，复制按钮与辅助功能树也不会保留明文。
private struct LocalIPResultContent: View {
  let source: LocalIPQuery.Source
  let response: LocalIPQuery.Response?
  let hideIP: Bool
  let hideDetails: Bool

  var body: some View {
    if hideDetails {
      Label(tr("信息已隐藏"), systemImage: "eye.slash")
        .font(.callout).foregroundStyle(.secondary)
    } else if let response {
      switch response {
      case .success(let result):
        VStack(alignment: .leading, spacing: DS.Space.s2) {
          if hideIP {
            Text("••••••••").accessibilityLabel(tr("隐藏 IP"))
          } else if let ip = result.ipv4 ?? result.ipv6 {
            CopyableText(text: ip).font(.system(.body, design: .monospaced))
          }
          if source == .ipv4 || source == .ipv6 {
            if let location = Self.location(result) {
              InfoRow(label: tr("归属地"), text: location)
            }
            if let organization = result.organization {
              InfoRow(label: tr("网络运营方"), text: organization)
            }
            if let asn = result.asn { InfoRow(label: "ASN", text: asn) }
          } else if let location = Self.location(result) {
            Text(verbatim: location).font(.callout).foregroundStyle(.secondary)
          }
        }
      case .failure(let failure):
        Label(Self.failureText(failure, source: source), systemImage: "exclamationmark.circle")
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else {
      HStack {
        ProgressView().controlSize(.small)
        Text(tr("查询中…")).font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  private static func failureText(_ failure: LocalIPQuery.Failure, source: LocalIPQuery.Source)
    -> String
  {
    switch failure {
    case .connection, .cancelled:
      source == .ipv6
        ? tr("未获取到 IPv6 地址，请检查网络或稍后重试。")
        : tr("未获取到地址，请检查网络或稍后重试。")
    case .http(429): tr("查询次数已达上限，请稍后重试。")
    case .http: tr("查询服务暂时不可用，请稍后重试。")
    case .invalidResponse: tr("查询服务返回了无效响应，请重试。")
    }
  }

  private static func location(_ value: PublicAddresses) -> String? {
    let country = value.countryCode.flatMap { L10n.locale.localizedString(forRegionCode: $0) }
    let region = L10n.usesEnglishNames ? value.regionEnglish ?? value.region : value.region
    let city = L10n.usesEnglishNames ? value.cityEnglish ?? value.city : value.city
    var parts: [String] = []
    for part in [country, region, city].compactMap({ $0 }) where parts.last != part {
      parts.append(part)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
