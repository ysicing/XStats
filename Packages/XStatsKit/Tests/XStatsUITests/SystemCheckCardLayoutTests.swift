// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct SystemCheckCardLayoutTests {
  @Test func idleCardRendersAllScopesInBothLayoutDirections() throws {
    let suite = "SystemCheckCardLayoutTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = []
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.aiUsageEnabled = false
    settings.aiUsageSources = []
    settings.cleanerEnabled = true
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [],
      networkCacheDefaults: defaults)
    let check = model.systemCheck
    // AppModel 不支持注入检查器；暂停确保布局测试不会触发真实检查。
    check.setPaused(true)
    defer {
      check.cancel()
      model.aiUsage.stop()
    }
    let width = DS.Size.panelWidth
    for scope in SystemCheckController.Scope.allCases {
      check.selectScope(scope)
      for direction in [LayoutDirection.leftToRight, .rightToLeft] {
        let host = NSHostingView(
          rootView: SystemCheckCard()
            .environment(model)
            .environment(\.layoutDirection, direction)
            .environment(\.isSnapshot, true)
            .preferredColorScheme(.light)
            .padding(DS.Space.s3)
            .frame(width: width, alignment: .leading)
            .background(DS.Palette.background))
        let size = host.fittingSize
        try #require(
          size.width.isFinite && size.height.isFinite && abs(size.width - width) < 1
            && size.height > 0 && size.height < 600)
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
        if let path = ProcessInfo.processInfo.environment["XSTATS_SYSTEM_CHECK_PREVIEW_DIR"] {
          let directory = URL(fileURLWithPath: path, isDirectory: true)
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
          let name =
            "system-check-\(scope.rawValue)-\(direction == .leftToRight ? "ltr" : "rtl").png"
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: directory.appendingPathComponent(name))
        }
      }
    }
    #expect(settings.enabledMonitoringModules.isEmpty && !model.demand.hasSamples)
  }
}
