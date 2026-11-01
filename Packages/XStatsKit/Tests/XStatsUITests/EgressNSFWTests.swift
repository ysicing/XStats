// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Localization
import Metrics
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EgressNSFWTests {
  private let zone = TimeZone(identifier: "Asia/Shanghai")!

  @Test func hardwareSalesRegionRequiresAnExplicitMainlandCode() {
    #expect(EgressNSFWPolicy.isMainlandChinaDevice(regionInfo: Data("CH/A".utf8)))
    #expect(
      EgressNSFWPolicy.isMainlandChinaDevice(
        regionInfo: Data("CH/A".utf8) + Data(repeating: 0, count: 28)))
    for info in [
      nil, Data(), Data("LL/A".utf8), Data("ZP/A".utf8), Data("CN".utf8),
      Data("CH/AX".utf8), Data([0xFF]), Data(repeating: 0, count: 65),
    ] {
      #expect(!EgressNSFWPolicy.isMainlandChinaDevice(regionInfo: info))
    }
  }

  @Test(
    arguments: AppLanguage.allCases.filter { $0 != .system }, [false, true])
  func settingsAndSitesRequireSimplifiedChineseAndMainlandHardware(
    language: AppLanguage, mainlandHardware: Bool
  ) throws {
    let name = "EgressNSFWEligibility.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    // 已保存的开启状态不能绕过语言和设备限制。
    defaults.set(true, forKey: "egressNSFWEnabled")
    defaults.set(false, forKey: "egressHideNSFWDuringWork")
    let controller = EgressController(
      defaults: defaults, now: { date("2026-09-24T23:00:00") }, timeZone: { zone },
      language: { language }, isMainlandChinaDevice: mainlandHardware)
    let session = EgressWindowSession(egress: controller)
    let eligible = language == .chinese && mainlandHardware
    #expect(controller.nsfwAvailable == eligible)
    #expect(controller.nsfwVisible == eligible)
    #expect(session.tabs.contains(.nsfw) == eligible)
    #expect(controller.visibleSites.contains { $0.category == .nsfw } == eligible)
    #expect(controller.nsfwEnabled && !controller.hideNSFWDuringWork)
    session.select(.nsfw)
    #expect(session.tab == (eligible ? .nsfw : .overview))
    #expect(controller.jobCount == EgressProber.jobCount)
    #expect(defaults.bool(forKey: "egressNSFWEnabled"))
  }

  @Test func languageChangesHideNSFWAndInvalidateSelectionWithoutChangingPreferences() throws {
    let name = "EgressNSFWLanguage.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var language = AppLanguage.chinese
    let controller = EgressController(
      defaults: defaults, now: { date("2026-09-24T23:00:00") }, timeZone: { zone },
      language: { language }, isMainlandChinaDevice: true)
    controller.nsfwEnabled = true
    let session = EgressWindowSession(egress: controller)
    session.select(.nsfw)
    #expect(session.tab == .nsfw)
    for excludedLanguage in [AppLanguage.traditionalChinese, .english, .arabic] {
      language = excludedLanguage
      controller.refreshNSFWVisibility()
      #expect(!controller.nsfwAvailable && !controller.nsfwVisible)
      #expect(session.tab == .overview && !session.tabs.contains(.nsfw))
      #expect(controller.visibleSites.allSatisfy { $0.category != .nsfw })
      #expect(controller.nsfwEnabled && controller.hideNSFWDuringWork)
      #expect(controller.checkTask == nil)
      language = .chinese
      controller.refreshNSFWVisibility()
      #expect(controller.nsfwAvailable && controller.nsfwVisible)
      #expect(session.tabs.contains(.nsfw) && session.tab == .overview)
    }
  }

  @Test func categoryTabsWrapForLongTranslationsInBothDirections() throws {
    _ = NSApplication.shared
    let titles = ["全部", "AI", "影音", "社交", "开发", "中国大陆", "NSFW", "WebRTC", "DNS"]
    for language in [AppLanguage.chinese, .english, .german, .french, .arabic] {
      let options = titles.enumerated().map { index, title in
        (index, L10n.translate(title, language: language))
      }
      for direction in [LayoutDirection.leftToRight, .rightToLeft] {
        let wide = NSHostingView(
          rootView: SegmentedControl(selection: .constant(6), options: options, wraps: true)
            .environment(\.layoutDirection, direction).frame(width: 960))
        let narrow = NSHostingView(
          rootView: SegmentedControl(selection: .constant(6), options: options, wraps: true)
            .environment(\.layoutDirection, direction).frame(width: 320)
            .background(DS.Palette.background))
        let size = narrow.fittingSize
        #expect(abs(size.width - 320) < 1)
        #expect(size.height > wide.fittingSize.height)
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = narrow
        narrow.layoutSubtreeIfNeeded()
        let bitmap = try #require(narrow.bitmapImageRepForCachingDisplay(in: narrow.bounds))
        narrow.cacheDisplay(in: narrow.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["XSTATS_EGRESS_TABS_PREVIEW_DIR"] {
          let suffix = direction == .leftToRight ? "ltr" : "rtl"
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: path).appendingPathComponent(
              "\(language.rawValue)-\(suffix).png"))
        }
      }
    }
  }

  @Test func narrowWindowRendersWithNSFWSelectedInBothDirections() async throws {
    _ = NSApplication.shared
    let name = "EgressNSFWLayout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let controller = EgressController(
      defaults: defaults, now: { date("2026-09-24T23:00:00") }, timeZone: { zone },
      language: { .chinese }, isMainlandChinaDevice: true,
      environmentReader: { ProxyEnvironment() },
      measure: { _, sites, _ in sites.map { EgressHit(targetID: $0.id, route: .system) } },
      geoLookup: { _, _, _ in nil })
    controller.nsfwEnabled = true
    controller.check()
    await controller.checkTask?.value
    let session = EgressWindowSession(egress: controller)
    session.select(.nsfw)
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let host = NSHostingView(
        rootView: EgressWindowView(session: session).content
          .environment(\.layoutDirection, direction).frame(width: 576))
      let size = host.fittingSize
      #expect(abs(size.width - 576) < 1)
      try #require(size.height.isFinite && size.height > 0)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 576, height: 640),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
      let suffix = direction == .leftToRight ? "ltr" : "rtl"
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: "/private/tmp/xstats-nsfw-\(suffix).png"))
    }
    #expect(!session.isChecking)
  }

  @Test func workHoursRespectBoundariesHolidaysAndMakeupWeekends() {
    for day in ["2026-09-20", "2026-09-24"] {
      #expect(!EgressNSFWPolicy.isWorkHours(at: date("\(day)T07:59:59"), timeZone: zone))
      #expect(EgressNSFWPolicy.isWorkHours(at: date("\(day)T08:00:00"), timeZone: zone))
      #expect(EgressNSFWPolicy.isWorkHours(at: date("\(day)T21:59:59"), timeZone: zone))
      #expect(!EgressNSFWPolicy.isWorkHours(at: date("\(day)T22:00:00"), timeZone: zone))
    }
    for day in ["2026-09-25", "2026-09-26", "2026-10-05"] {
      #expect(!EgressNSFWPolicy.isWorkHours(at: date("\(day)T12:00:00"), timeZone: zone))
    }
    #expect(EgressNSFWPolicy.isWorkHours(at: date("2099-09-20T12:00:00"), timeZone: zone))
    #expect(!EgressNSFWPolicy.isWorkHours(at: date("2099-09-20T22:00:00"), timeZone: zone))
  }

  @Test func policyUsesLocalTimeAndSchedulesTheNextBoundary() throws {
    let morning = date("2026-09-24T08:00:00")
    #expect(EgressNSFWPolicy.isWorkHours(at: morning, timeZone: zone))
    #expect(!EgressNSFWPolicy.isWorkHours(at: morning, timeZone: TimeZone(secondsFromGMT: 0)!))
    #expect(
      EgressNSFWPolicy.nextBoundary(after: date("2026-09-24T07:59:59"), timeZone: zone)
        == morning)
    #expect(
      EgressNSFWPolicy.nextBoundary(after: morning, timeZone: zone)
        == date("2026-09-24T22:00:00"))
    #expect(
      EgressNSFWPolicy.nextBoundary(after: date("2026-09-24T22:00:00"), timeZone: zone)
        == date("2026-09-25T08:00:00"))
  }

  @Test func optInControlsOnlyVisibleSitesAndTab() throws {
    let name = "EgressNSFWDefaults.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let controller = EgressController(
      defaults: defaults, now: { date("2026-09-24T23:00:00") }, timeZone: { zone },
      language: { .chinese }, isMainlandChinaDevice: true)
    let session = EgressWindowSession(egress: controller)
    #expect(!controller.nsfwEnabled)
    #expect(controller.hideNSFWDuringWork)
    #expect(!session.tabs.contains(.nsfw))
    #expect(controller.visibleSites.allSatisfy { $0.category != .nsfw })
    #expect(EgressTarget.sites.filter { $0.category == .nsfw } == EgressTarget.nsfwSites)
    #expect(
      Set(EgressTarget.nsfwSites.map(\.host)) == [
        "missav.ws", "missav.ai", "missav.live", "javdb.com",
      ])
    #expect(
      EgressTarget.nsfwSites.allSatisfy {
        $0.category == .nsfw && $0.region == .international
          && EgressWindowSession.Tab.nsfw.includes($0)
      })
    controller.nsfwEnabled = true
    #expect(session.tabs.contains(.nsfw))
    #expect(controller.visibleSites.count == EgressTarget.sites.count)
    #expect(controller.jobCount == EgressProber.jobCount)
    session.select(.nsfw)
    #expect(session.tab == .nsfw)
    controller.nsfwEnabled = false
    #expect(session.tab == .overview)
    controller.nsfwEnabled = true
    controller.hideNSFWDuringWork = false
    let restored = EgressController(
      defaults: defaults, now: { date("2026-09-24T12:00:00") }, timeZone: { zone },
      language: { .chinese }, isMainlandChinaDevice: true)
    #expect(restored.nsfwEnabled && !restored.hideNSFWDuringWork && restored.nsfwVisible)
  }

  @Test func hiddenSitesAreMeasuredAndCachedLikeOtherSites() async throws {
    let name = "EgressNSFWSelection.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let probe = NSFWProbe()
    let controller = EgressController(
      defaults: defaults, now: { date("2026-09-20T12:00:00") }, timeZone: { zone },
      language: { .chinese }, isMainlandChinaDevice: true,
      environmentReader: { ProxyEnvironment() },
      measure: { _, sites, _ in await probe.measure(sites) }, geoLookup: { _, _, _ in nil })
    controller.check()
    await controller.checkTask?.value
    #expect(await probe.hosts == Set(EgressTarget.sites.map(\.host)))
    #expect(await probe.hosts.isSuperset(of: Set(EgressTarget.nsfwSites.map(\.host))))
    let report = try #require(controller.report)
    controller.nsfwEnabled = true
    #expect(!controller.nsfwVisible)
    #expect(controller.report == report)
    controller.hideNSFWDuringWork = false
    #expect(controller.report == report)
    #expect(controller.report?.hits.contains { $0.targetID == "javdb.com" } == true)
    let data = try #require(defaults.data(forKey: "egressReport2"))
    let cached = try JSONDecoder().decode(EgressController.Report.self, from: data)
    #expect(cached == report)
    #expect(cached.hits.contains { $0.targetID == "javdb.com" })
    controller.nsfwEnabled = false
    #expect(controller.report == report)
    #expect(controller.analysis?.failedTargetIDs.contains("javdb.com") == true)
    #expect(controller.visibleSites.allSatisfy { $0.category != .nsfw })
  }

  @Test func enteringWorkHoursOnlyHidesDisplayAndKeepsTheRunningCheck() async throws {
    let name = "EgressNSFWBoundary.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var clock = date("2026-09-24T07:59:59")
    let gate = NSFWProbe(held: true)
    let controller = EgressController(
      defaults: defaults, now: { clock }, timeZone: { zone },
      language: { .chinese }, isMainlandChinaDevice: true,
      environmentReader: { ProxyEnvironment() },
      measure: { _, sites, progress in
        let hits = await gate.measure(sites)
        progress(99)
        return hits
      }, geoLookup: { _, _, _ in nil })
    controller.nsfwEnabled = true
    let session = EgressWindowSession(egress: controller)
    session.select(.nsfw)
    controller.check()
    let task = try #require(controller.checkTask)
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await gate.started), ContinuousClock.now < deadline { await Task.yield() }
    try #require(await gate.started)
    clock = date("2026-09-24T08:00:00")
    controller.refreshNSFWVisibility()
    #expect(controller.isChecking && !controller.nsfwVisible)
    #expect(!task.isCancelled)
    #expect(session.tab == .overview && !session.tabs.contains(.nsfw))
    await gate.release()
    await task.value
    await Task.yield()
    #expect(controller.progress == 99)
    #expect(controller.report?.hits.contains { $0.targetID == "javdb.com" } == true)
    #expect(defaults.data(forKey: "egressReport2") != nil)
    let report = controller.report
    clock = date("2026-09-24T22:00:00")
    controller.refreshNSFWVisibility()
    #expect(session.tabs.contains(.nsfw))
    #expect(session.tab == .overview)
    #expect(controller.report == report)
  }

  @Test func reopeningAndCacheLoadingPreserveHiddenResults() async throws {
    let name = "EgressNSFWCache.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let report = EgressController.Report(
      date: date("2026-09-24T07:00:00"), environment: ProxyEnvironment(),
      hits: [
        EgressHit(targetID: "javdb.com", route: .system),
        EgressHit(targetID: "github.com", route: .system),
      ], geo: [:])
    defaults.set(try JSONEncoder().encode(report), forKey: "egressReport2")
    var clock = date("2026-09-24T07:00:00")
    let controller = EgressController(
      defaults: defaults, now: { clock }, timeZone: { zone },
      language: { .chinese }, isMainlandChinaDevice: true,
      environmentReader: { ProxyEnvironment() },
      measure: { _, _, _ in [EgressHit(targetID: "javdb.com", route: .system)] },
      geoLookup: { _, _, _ in nil })
    #expect(controller.report == report)
    let cached = try JSONDecoder().decode(
      EgressController.Report.self, from: #require(defaults.data(forKey: "egressReport2")))
    #expect(cached == report)
    controller.nsfwEnabled = true
    controller.check()
    await controller.checkTask?.value
    #expect(controller.report?.hits.count == 1)
    controller.windowDidClose()
    clock = date("2026-09-24T09:00:00")
    controller.windowDidOpen(automaticallyChecks: false)
    defer { controller.windowDidClose() }
    #expect(!controller.nsfwVisible)
    #expect(controller.visibleSites.allSatisfy { $0.category != .nsfw })
    #expect(controller.report?.hits.map(\.targetID) == ["javdb.com"])
  }

  private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text + "+08:00")!
  }
}

private actor NSFWProbe {
  private let held: Bool
  private var gate: CheckedContinuation<Void, Never>?
  private(set) var started = false
  private(set) var hosts: Set<String> = []

  init(held: Bool = false) { self.held = held }

  func measure(_ sites: [EgressTarget]) async -> [EgressHit] {
    hosts = Set(sites.map(\.host))
    started = true
    if held { await withCheckedContinuation { gate = $0 } }
    return sites.map { EgressHit(targetID: $0.id, route: .system) }
  }

  func release() {
    gate?.resume()
    gate = nil
  }
}
