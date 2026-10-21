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
      ] {
        #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
      }
    }
  }

  @Test func querySheetRendersWithIsolatedData() async throws {
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let host = NSHostingView(
        rootView: LocalIPQueryView(query: { source in
          if source == .ipv6 { return nil }
          if source == .domestic { return PublicAddresses(ipv4: "198.51.100.2") }
          if source == .cloudflare {
            return PublicAddresses(ipv4: "203.0.113.24", countryCode: "JP")
          }
          return PublicAddresses(
            ipv4: "203.0.113.24", countryCode: "JP", city: "Example City",
            region: "Example Region", asn: "AS64500", organization: "Example Network Operator")
        })
        .environment(\.layoutDirection, direction))
      host.appearance = NSAppearance(named: direction == .leftToRight ? .aqua : .darkAqua)
      let size = host.fittingSize
      #expect(size.width == 720 && size.height == 580)
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
