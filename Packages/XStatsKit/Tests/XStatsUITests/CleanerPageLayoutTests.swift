// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct CleanerPageLayoutTests {
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

  @Test func bothTabsRenderWithoutStartingWorkInBothLayoutDirections() throws {
    let suite = "CleanerPageLayoutTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = []
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.aiUsageEnabled = false
    settings.aiUsageSources = []
    settings.cleanerEnabled = true
    settings.panelTab = .cleaner
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [],
      networkCacheDefaults: defaults)
    let check = model.systemCheck
    defer {
      check.cancel()
      model.cleaner.cancelOperation()
      model.aiUsage.stop()
    }
    let width = DS.Size.panelWidth
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
        #expect(model.cleaner.phase == .idle && model.cleaner.scans.isEmpty)
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
