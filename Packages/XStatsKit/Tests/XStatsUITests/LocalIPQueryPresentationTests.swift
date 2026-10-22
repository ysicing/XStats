// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import Localization
@testable import Metrics
@testable import XStatsUI

@MainActor
struct LocalIPQueryPresentationTests {
  @Test func translationsExistWithoutChangingGlobalLanguage() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in [
        "本机 IP 查询", "按需连接第三方服务，查看它们看到的公网出口。不同来源可能经过不同代理路线。",
        "隐藏 IP", "隐藏国内信息", "隐藏国际信息", "信息已隐藏", "未获取到地址，请检查网络或稍后重试。",
        "出口对比", "查看网站连通性与代理路线", "未获取到 IPv6 地址，请检查网络或稍后重试。",
        "查询次数已达上限，请稍后重试。", "查询服务暂时不可用，请稍后重试。", "查询服务返回了无效响应，请重试。",
        "国际", "本地接口", "暂无已连接的本地接口", "有线网络", "VPN / 隧道", "其他接口", "更多地址", "链路本地",
      ] {
        #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
      }
    }
  }

  @Test func querySheetRendersWithIsolatedData() async throws {
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let host = NSHostingView(
        rootView: LocalIPQueryView(
          query: { source in
            if source == .ipv6 { return .failure(.connection) }
            if source == .domestic { return .success(PublicAddresses(ipv4: "198.51.100.2")) }
            if source == .cloudflare {
              return .success(PublicAddresses(ipv4: "203.0.113.24", countryCode: "JP"))
            }
            if source == .ipify { return .success(PublicAddresses(ipv4: "192.0.2.42")) }
            return .success(
              PublicAddresses(
                ipv4: "203.0.113.24", countryCode: "JP", city: "Example City",
                region: "Example Region", asn: "AS64500", organization: "Example Network Operator"))
          },
          readInterfaces: {
            [
              LocalNetworkInterface(
                bsdName: "en0", name: "Wi-Fi", kind: .wifi, ipv4: ["192.168.1.20"],
                ipv6: ["2001:db8:1234:5678:abcd:ef01:2345:6789", "fd00::20"],
                linkLocal: ["fe80::20"]),
              LocalNetworkInterface(
                bsdName: "en7", name: "USB Ethernet", kind: .ethernet, ipv4: ["10.0.0.20"]),
              LocalNetworkInterface(
                bsdName: "utun6", name: "Tailscale", kind: .tunnel, ipv4: ["100.80.1.2"],
                ipv6: ["fd7a:115c:a1e0::1"]),
              LocalNetworkInterface(
                bsdName: "utun9", name: "WireGuard", kind: .tunnel, ipv4: ["10.8.0.2"]),
            ]
          }
        )
        .environment(\.layoutDirection, direction))
      host.appearance = NSAppearance(named: direction == .leftToRight ? .aqua : .darkAqua)
      let size = host.fittingSize
      #expect(size.width == 780 && size.height == 560)
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      defer { window.close() }
      // 让 SwiftUI 挂载并消费立即返回的演示结果；不访问第三方服务。
      try await Task.sleep(for: .milliseconds(200))
      host.layoutSubtreeIfNeeded()
      #expect(host.fittingSize == size)
      if let path = ProcessInfo.processInfo.environment["XSTATS_IP_PREVIEW_DIR"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: directory.appendingPathComponent("ip-\(direction).png"))
      }
    }
  }

}
