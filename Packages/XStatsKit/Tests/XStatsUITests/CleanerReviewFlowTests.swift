// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct CleanerReviewFlowTests {
  @Test func incompleteUninstallScanKeepsVerifiedItemsAndConfirmationAvailable() async throws {
    let app = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/Fixture.app"), name: "Fixture",
      bundleIdentifier: "com.example.fixture", version: nil, teamIdentifier: nil)
    let body = AppLeftover(url: app.url, kind: .application, size: 100)
    let controller = UninstallerController(
      currentBundleIdentifier: nil,
      findLeftoversReport: { _ in
        AppLeftoverScan(
          items: [body],
          unreadablePaths: [URL(fileURLWithPath: "/Users/demo/Library/Caches/OtherVendor")])
      }, recycleFiles: { _, _ in Issue.record("Review must not remove files") })
    defer { controller.setEnabled(false) }
    let scan = try #require(controller.select(app))
    await scan.value
    try #require(!controller.isScanning)
    #expect(controller.scanIncomplete && controller.canUninstall && controller.leftovers == [body])
    controller.requestUninstall()
    #expect(controller.pendingUninstall == app)
    controller.cancelUninstall()
    controller.select(nil)
    #expect(!controller.scanIncomplete && !controller.canUninstall)
  }

  @Test func exclusionCapacityFailureDoesNotKeepTheItemSelected() throws {
    let suite = "CleanerExclusionCapacityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.cleanerEnabled = false  // 仅验证选择和持久化，不扫描用户目录。
    settings.cleanExcludedPaths = (0..<49).map { "/Users/demo/keep/\($0)" }
    let controller = CleanerController(settings: settings)
    let rule = try #require(RuleCatalog.rules().first { $0.id == "system.caches" })
    let last = CleanItem(url: URL(fileURLWithPath: "/Users/demo/Library/Caches/last"), size: 100)
    let overflow = CleanItem(
      url: URL(fileURLWithPath: "/Users/demo/Library/Caches/overflow"), size: 200)
    let scan = RuleScan(rule: rule, items: [last, overflow], skippedCount: 0, blocked: nil)
    controller.showPreview([scan])
    #expect(controller.exclude(last.url))
    #expect(controller.exclusionLimitReached && controller.excludedPaths.count == 50)
    controller.isConfirming = true
    #expect(!controller.exclude(overflow.url))
    #expect(!controller.isConfirming && controller.selectedScans.isEmpty)
    #expect(!controller.excludedPaths.contains(overflow.url.path))
    controller.removeExclusion(last.url.path)
    #expect(!controller.exclusionLimitReached)
    #expect(controller.exclude(overflow.url))
    #expect(controller.excludedPaths.contains(overflow.url.path))
  }

  @Test func itemChoicesAffectConfirmationAndWholeRuleToggleRestoresSelection() throws {
    let suite = "CleanerReviewTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let controller = CleanerController(settings: settings)
    let root = URL(fileURLWithPath: "/Users/demo/Library/Caches")
    let first = CleanItem(url: root.appendingPathComponent("com.example.first"), size: 100)
    let second = CleanItem(url: root.appendingPathComponent("com.example.second"), size: 200)
    let rule = try #require(RuleCatalog.rules().first { $0.id == "system.caches" })
    let scan = RuleScan(rule: rule, items: [first, second], skippedCount: 0, blocked: nil)
    controller.showPreview([scan])
    #expect(controller.selectedBytes == 300)
    controller.toggle(first, in: scan)
    #expect(controller.selectedBytes == 200 && controller.selectedScans.first?.items == [second])
    controller.toggle(scan)  // 部分选择补齐，而不是清空。
    #expect(controller.selectedItems(in: scan).count == 2)
    controller.toggle(first, in: scan)
    controller.toggle(second, in: scan)
    #expect(controller.selectedScans.isEmpty && controller.selectedBytes == 0)
    controller.toggle(scan)
    #expect(controller.selectedItems(in: scan) == [first, second])
    controller.toggle(scan)
    controller.toggle(first, in: scan)
    #expect(controller.selectedItems(in: scan) == [first])
    settings.cleanExcludedPaths = [first.url.path]
    #expect(controller.selectedScans.isEmpty)
  }

  @Test func exclusionsStayLocalAndPersistAcrossSettingsRecreation() throws {
    let suite = "CleanerExclusionTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.cleanExcludedPaths = ["/Users/demo/Library/Caches/keep"]
    #expect(AppSettings(defaults: defaults).cleanExcludedPaths == settings.cleanExcludedPaths)
    let data = try JSONEncoder().encode(settings.exportDocument())
    #expect(!String(decoding: data, as: UTF8.self).contains("/Users/demo/Library/Caches/keep"))
  }
}
