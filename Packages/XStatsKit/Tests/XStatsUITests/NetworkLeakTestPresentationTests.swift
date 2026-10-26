// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import Localization
@testable import Metrics
@testable import XStatsUI

@MainActor
struct NetworkLeakTestPresentationTests {
  @Test func egressWindowRendersAllTabsWithoutStartingLeakTests() async throws {
    let name = "EgressPresentation.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = []
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.aiUsageEnabled = false
    settings.aiUsageSources = []
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [],
      networkCacheDefaults: defaults)
    defer { model.aiUsage.stop() }
    let session = EgressWindowSession(egress: model.egress)
    defer { session.close() }
    for tab in EgressWindowSession.Tab.allCases {
      session.select(tab)
      for width in [576.0, 960.0] {
        let size = NSSize(width: width, height: 640)
        let host = NSHostingView(rootView: EgressWindowView(session: session).environment(model))
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size),
          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: width == 576 ? .aqua : .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= width)
        #expect(session.webRTC.phase == .idle)
        #expect(session.dns.phase == .idle)
        #expect(!model.egress.isChecking)
        if let directory = ProcessInfo.processInfo.environment["XSTATS_LEAK_PREVIEW_DIR"] {
          let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(
              "egress-\(tab)-\(Int(width)).png"))
        }
        window.close()
      }
    }
  }

  @Test func sheetRendersLongAddressesAndHiddenState() async throws {
    for mode in NetworkLeakTestController.Mode.allCases {
      for hidden in [false, true] {
        let controller = NetworkLeakTestController()
        controller.phase = .complete
        controller.httpExit = "192.0.2.1"
        controller.candidates = [
          try #require(
            NetworkLeakTest.candidate(
              "candidate:a 1 udp 100 2001:db8:1234:5678:abcd:ef01:2345:6789 1234 typ srflx"))
        ]
        controller.dnsResult = try NetworkLeakTest.decodeDNS(
          Data(
            """
            [{"ip":"192.0.2.1","type":"ip"},
             {"ip":"2001:db8:1234:5678:abcd:ef01:2345:6789","type":"dns",
              "country_name":"Example region","org":"Example International Network Operator"}]
            """.utf8))
        let host = NSHostingView(
          rootView:
            NetworkLeakTestView(controller: controller, mode: mode, hideIP: .constant(hidden))
            .frame(width: 640, height: 480)
            .environment(\.layoutDirection, hidden ? .rightToLeft : .leftToRight))
        let size = NSSize(width: 640, height: 480)
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size),
          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: hidden ? .darkAqua : .aqua)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize == size)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["XSTATS_LEAK_PREVIEW_DIR"] {
          let url = URL(fileURLWithPath: directory).appendingPathComponent(
            "\(mode.rawValue)-\(hidden).png")
          try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
      }
    }
  }

  @Test func longTranslationsFitInformationPopover() throws {
    for language in AppLanguage.allCases where language != .system {
      let text = L10n.translate(
        "检测 XStats 内 WebKit 暴露的地址，不代表其他浏览器。开始后连接 Cloudflare、Google、BlackBerry、Twilio STUN 与 ipify。",
        language: language)
      let host = NSHostingView(
        rootView: Text(text).dsFont(.sm)
          .fixedSize(horizontal: false, vertical: true).frame(width: 328)
          .environment(\.layoutDirection, language == .arabic ? .rightToLeft : .leftToRight))
      #expect(host.fittingSize.height <= 180, "\(language)")
    }
  }

}
