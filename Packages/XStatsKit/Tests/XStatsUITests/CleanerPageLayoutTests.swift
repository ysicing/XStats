// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Localization
import Metrics
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct CleanerPageLayoutTests {
  @Test func scanStatusDistinguishesEmptyCachesTimeoutsAndReadFailures() throws {
    let rules = RuleCatalog.rules()
    let cleanable = try #require(rules.first { $0.id == "developer.go" })
    let preview = try #require(rules.first { $0.id == "preview.quickLook" })
    let empty = RuleScan(rule: preview, items: [], skippedCount: 0, blocked: nil)
    #expect(empty.cleanupStatusText(selectedCount: 0) == tr("未发现缓存"))
    let unreadable = RuleScan(
      rule: preview, items: [], skippedCount: 0, blocked: nil, unreadableCount: 2)
    #expect(unreadable.cleanupStatusText(selectedCount: 0) == tr("\(2) 个文件或目录无法读取"))
    let running = RuleScan(
      rule: preview, items: [], skippedCount: 0, blocked: .appRunning("Fixture"))
    #expect(running.cleanupStatusText(selectedCount: 0) == SkipReason.appRunning("Fixture").title)
    let measured = RuleScan(
      rule: preview, items: [CleanItem(url: URL(fileURLWithPath: "/fixture/cache"), size: 4096)],
      skippedCount: 0, blocked: nil)
    #expect(measured.cleanupStatusText(selectedCount: 0) == tr("不支持清理 · \(tr("\(1) 项"))"))
    #expect(!measured.isCleanable)
    let timedOut = RuleScan(
      rule: cleanable, items: [], skippedCount: 0, blocked: nil, interruption: .timeLimit)
    #expect(timedOut.cleanupStatusText(selectedCount: 0) == tr("工具预览超时，暂不可清理"))
  }

  @Test func applicationCachesAreGroupedWithoutDuplicatingOrHidingRules() throws {
    let rules = RuleCatalog.rules()
    let applicationCaches = CleanerPage.Section.applicationCaches
    let sections = [applicationCaches] + CleanCategory.allCases.map(CleanerPage.Section.category)
    let applicationIDs = Set(rules.filter { applicationCaches.contains($0) }.map(\.id))
    #expect(
      Set(["system.caches", "app.codex", "preview.teams", "preview.telegram", "preview.chatgpt"])
        .isSubset(of: applicationIDs))
    #expect(!applicationIDs.contains("system.logs"))
    for rule in rules {
      #expect(sections.filter { $0.contains(rule) }.count == 1)
      if rule.category != .system {
        #expect(CleanerPage.Section.category(rule.category).contains(rule))
      }
    }
    let logs = try #require(rules.first { $0.id == "system.logs" })
    #expect(CleanerPage.Section.category(.system).contains(logs))
  }

  @Test func spotlightGuidanceFitsInBothLayoutDirections() throws {
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let host = NSHostingView(
        rootView: SpotlightRepairSheet()
          .environment(\.layoutDirection, direction)
          .frame(width: 600))
      let size = host.fittingSize
      #expect(size.width == 600 && size.height > 0 && size.height < 700)
    }
  }

  @Test func bothTabsRenderWithoutStartingWorkInBothLayoutDirections() throws {
    let suite = "CleanerPageLayoutTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = []
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.aiUsageEnabled = false

    settings.cleanerEnabled = true
    settings.panelTab = .cleaner
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient(),
      networkCacheDefaults: defaults)
    let check = model.systemCheck
    defer {
      check.cancel()
      model.cleaner.cancelOperation()
      model.aiUsage.stop()
    }
    let width = DS.Size.panelWidth
    let rules = RuleCatalog.rules()
    let go = try #require(rules.first { $0.id == "developer.go" })
    let logs = try #require(rules.first { $0.id == "system.logs" })
    let quickLook = try #require(rules.first { $0.id == "preview.quickLook" })
    model.cleaner.showPreview([
      RuleScan(rule: go, items: [], skippedCount: 0, blocked: nil, interruption: .timeLimit),
      RuleScan(rule: logs, items: [], skippedCount: 0, blocked: nil, unreadableCount: 2),
      RuleScan(rule: quickLook, items: [], skippedCount: 0, blocked: nil),
    ])
    for tab in CleanerPage.Tab.allCases {
      for direction in [LayoutDirection.leftToRight, .rightToLeft] {
        let host = NSHostingView(
          rootView: VStack(spacing: 0) {
            PageHeader(cleanerTab: .constant(tab))
            CleanerPage(tab: .constant(tab))
          }
          .environment(model)
          .environment(\.layoutDirection, direction)
          .environment(\.isSnapshot, true)
          .preferredColorScheme(.light)
          .frame(width: width, height: 700, alignment: .topLeading)
          .background(DS.Palette.background))
        let size = host.fittingSize
        try #require(
          size.width.isFinite && size.height.isFinite && abs(size.width - width) < 1
            && size.height > 0 && size.height < 800)
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - size.height) < 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        #expect(!check.isChecking && check.checkedAt == nil && check.findings.isEmpty)
        #expect(check.deadlineTask == nil)
        #expect(model.cleaner.phase == .ready && model.cleaner.scans.count == 3)
        #expect(
          !model.maintenance.isResettingThumbnails && model.maintenance.thumbnailOutcome == nil)
        if let path = ProcessInfo.processInfo.environment["XSTATS_CLEANER_PREVIEW_DIR"] {
          let directory = URL(fileURLWithPath: path, isDirectory: true)
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
          let name =
            "cleaner-\(tab.rawValue)-\(direction == .leftToRight ? "ltr" : "rtl").png"
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: directory.appendingPathComponent(name))
        }
      }
    }
    #expect(settings.enabledMonitoringModules.isEmpty && !model.demand.hasSamples)
  }
}
