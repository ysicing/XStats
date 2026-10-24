// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct CleanerApplicationVisibilityTests {
  @Test func hidesUnrelatedAppsButRetainsHistoryAndUncertainResults() throws {
    let suite = "CleanerApplicationVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let controller = CleanerController(settings: settings)
    let rules = RuleCatalog.rules()
    let rule = try #require(rules.first { $0.id == "preview.zoom" })
    let empty = RuleScan(rule: rule, items: [], skippedCount: 0, blocked: nil)
    let absent = CacheApplicationInventory(rules: rules, applications: [], isComplete: true)
    controller.showPreview([empty], applications: absent)
    #expect(!controller.shouldDisplay(empty))
    let occupied = RuleScan(
      rule: rule,
      items: [CleanItem(url: URL(fileURLWithPath: "/fixture/cache"), size: 20)],
      skippedCount: 0, blocked: nil)
    #expect(controller.shouldDisplay(occupied))
    #expect(controller.applicationState(for: occupied) == .cacheRemains)
    for scan in [
      RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .appRunning("Zoom")),
      RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .needsFullDiskAccess),
      RuleScan(rule: rule, items: [], skippedCount: 1, blocked: nil),
      RuleScan(rule: rule, items: [], skippedCount: 0, blocked: nil, unreadableCount: 1),
      RuleScan(rule: rule, items: [], skippedCount: 0, blocked: nil, interruption: .entryLimit),
    ] {
      #expect(controller.shouldDisplay(scan))
    }
    controller.showPreview(
      [empty],
      applications: CacheApplicationInventory(
        rules: rules, applications: [], isComplete: false))
    #expect(controller.shouldDisplay(empty))
    settings.cleanObservedApplicationRuleIDs = [rule.id]
    let recreated = CleanerController(settings: AppSettings(defaults: defaults))
    recreated.showPreview([empty], applications: absent)
    #expect(recreated.shouldDisplay(empty))
    #expect(recreated.applicationState(for: empty) == .previouslyInstalled)
    #expect(recreated.keepsEmptyVisible(empty))
    let system = try #require(rules.first { $0.id == "system.caches" })
    #expect(
      recreated.shouldDisplay(RuleScan(rule: system, items: [], skippedCount: 0, blocked: nil)))
  }

  @Test func confirmedInstallationIsRememberedAndReinstallationClearsHistoricalLabel() async throws
  {
    let suite = "CleanerApplicationVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let controller = CleanerController(settings: settings)
    let rules = RuleCatalog.rules()
    let rule = try #require(rules.first { $0.id == "preview.zoom" })
    let empty = RuleScan(rule: rule, items: [], skippedCount: 0, blocked: nil)
    let installed = CacheApplicationInventory(
      rules: rules,
      applications: [
        InstalledApp(
          url: URL(fileURLWithPath: "/Applications/Zoom.app"), name: "Zoom",
          bundleIdentifier: "us.zoom.xos", version: nil, teamIdentifier: nil)
      ], isComplete: true)
    controller.showPreview([empty], applications: installed)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      controller.rememberApplications(installed)
    }
    await cancelled.value
    #expect(settings.cleanObservedApplicationRuleIDs.isEmpty)
    controller.rememberApplications(installed)
    #expect(settings.cleanObservedApplicationRuleIDs.contains(rule.id))
    #expect(AppSettings(defaults: defaults).cleanObservedApplicationRuleIDs.contains(rule.id))
    #expect(controller.applicationState(for: empty) == .installed)
    controller.showPreview(
      [empty],
      applications: CacheApplicationInventory(
        rules: rules, applications: [], isComplete: true))
    #expect(controller.applicationState(for: empty) == .previouslyInstalled)
    controller.showPreview([empty], applications: installed)
    #expect(controller.applicationState(for: empty) == .installed)
    #expect(!controller.keepsEmptyVisible(empty))
  }
}
