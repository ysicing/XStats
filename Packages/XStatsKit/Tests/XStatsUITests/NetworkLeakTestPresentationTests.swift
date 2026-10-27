// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import Localization
@testable import Metrics
@testable import XStatsUI

@MainActor
struct NetworkLeakTestPresentationTests {
  @Test func windowZoomFitsContentWithoutStartingChecksOrExceedingScreen() throws {
    let name = "EgressWindowSizing.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = []
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.aiUsageEnabled = false
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [],
      networkCacheDefaults: defaults)
    defer { model.aiUsage.stop() }
    let controller = EgressWindowController(model: model)
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 1000, height: 1200),
      styleMask: [.titled, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentMinSize = NSSize(width: 576, height: 480)
    let original = window.frame
    let screen = NSRect(x: 0, y: 0, width: 1600, height: 1400)
    let fitted = controller.fittedFrame(for: window, within: screen)
    #expect(fitted.width == original.width)
    #expect(fitted.height < original.height)
    #expect(fitted.height >= window.contentMinSize.height)
    #expect(screen.contains(fitted))
    #expect(window.frame == original)
    #expect(!model.egress.isChecking)
    #expect(controller.fittedFrame(for: window, within: screen) == fitted)
    let smallScreen = NSRect(x: -800, y: -100, width: 800, height: 500)
    #expect(smallScreen.contains(controller.fittedFrame(for: window, within: smallScreen)))
  }

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
    let session = EgressWindowSession(
      egress: model.egress,
      makeController: {
        NetworkLeakTestController(
          webRTCProbe: { WebRTCLeakProbe.Result(services: []) },
          exitLookup: { "192.0.2.1" },
          dnsProbe: {
            try NetworkLeakTest.decodeDNS(Data("[{\"ip\":\"192.0.2.53\",\"type\":\"dns\"}]".utf8))
          })
      })
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
    // 已完成时间与另一项仍在检测的进度／取消按钮同时出现时，窄窗口也不能溢出。
    session.webRTC.start(.webRTC)
    session.dns.start(.dns)
    let deadline = ContinuousClock.now + .seconds(1)
    while session.isChecking, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.webRTC.completedAt != nil)
    #expect(session.dns.completedAt != nil)
    for tab in [EgressWindowSession.Tab.webRTC, .dns] {
      session.select(tab)
      for rightToLeft in [false, true] {
        let other = tab == .webRTC ? session.dns : session.webRTC
        other.phase = .running
        let host = NSHostingView(
          rootView: EgressWindowView(session: session).environment(model)
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight))
        host.frame = NSRect(x: 0, y: 0, width: 576, height: 640)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 576)
        other.phase = .complete
      }
    }
  }

  @Test func resultsRenderLongAddressesInBothLayoutDirections() async throws {
    for mode in NetworkLeakTestController.Mode.allCases {
      for rightToLeft in [false, true] {
        let controller = NetworkLeakTestController()
        controller.phase = .complete
        controller.httpExit = "192.0.2.1"
        let candidate = try #require(
          NetworkLeakTest.candidate(
            "candidate:a 1 udp 100 2001:db8:1234:5678:abcd:ef01:2345:6789 1234 typ srflx"))
        controller.webRTCServices = [
          .init(provider: .cloudflare, candidates: [candidate], status: .complete),
          .init(provider: .google, candidates: [candidate], status: .complete),
          .init(provider: .blackBerry, status: .failed),
          .init(provider: .twilio, status: .timedOut),
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
            NetworkLeakTestView(controller: controller, mode: mode)
            .frame(width: 640)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight))
        let size = NSSize(width: 640, height: 640)
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size),
          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: rightToLeft ? .darkAqua : .aqua)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == size.width)
        #expect(host.fittingSize.height <= size.height)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["XSTATS_LEAK_PREVIEW_DIR"] {
          let url = URL(fileURLWithPath: directory).appendingPathComponent(
            "\(mode.rawValue)-\(rightToLeft).png")
          try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
      }
    }
  }

  @Test func serviceStatusesTranslateWithoutChangingGlobalLanguage() {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      for source in [
        "通过四个 STUN 服务检测公网地址，与 HTTP 出口对照", "查看本次请求实际使用的 DNS 解析服务器",
        "未返回公网地址", "服务检测失败", "服务检测超时",
      ] {
        #expect(L10n.translate(source, language: language) != source, "\(language): \(source)")
      }
    }
  }

}
