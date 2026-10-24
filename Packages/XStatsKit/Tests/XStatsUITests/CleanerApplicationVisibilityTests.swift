// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct CleanerApplicationVisibilityTests {
  @Test func restoresOnlySupportedCleanupSelections() throws {
    let suite = "CleanerApplicationVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let rules = RuleCatalog.rules()
    settings.cleanSelectedRuleIDs = Set(rules.map(\.id))

    let controller = CleanerController(settings: settings)

    // 旧偏好可能包含已移除的仅查看项目，恢复选择时不能重新带入。
    #expect(controller.selection == Set(rules.filter { !$0.previewOnly }.map(\.id)))
  }

  @Test func hidesUnrelatedAppsButRetainsHistoryAndUncertainResults() throws {
    let suite = "CleanerApplicationVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let controller = CleanerController(settings: settings)
    let rules = RuleCatalog.rules()
    let rule = try #require(rules.first { $0.id == "app.slack" })
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
      RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .appRunning("Slack")),
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
    let rule = try #require(rules.first { $0.id == "app.slack" })
    let empty = RuleScan(rule: rule, items: [], skippedCount: 0, blocked: nil)
    let installed = CacheApplicationInventory(
      rules: rules,
      applications: [
        InstalledApp(
          url: URL(fileURLWithPath: "/Applications/Slack.app"), name: "Slack",
          bundleIdentifier: "com.tinyspeck.slackmacgap", version: nil, teamIdentifier: nil)
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
    // 清单读取失败或不完整时，已见过的应用不能凭历史标为“曾安装”。
    controller.showPreview([empty], applications: nil)
    #expect(controller.applicationState(for: empty) == .unknown)
    controller.showPreview(
      [empty],
      applications: CacheApplicationInventory(rules: rules, applications: [], isComplete: false))
    #expect(controller.applicationState(for: empty) == .unknown)
    #expect(controller.shouldDisplay(empty))
  }

  @Test func previewOnlyRulesStayHiddenAndDoNotRequestPermissions() throws {
    let suite = "CleanerApplicationVisibilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let controller = CleanerController(settings: settings)
    settings.cleanObservedApplicationRuleIDs = Set(PreviewRuleCatalog.rules.map(\.id))
    let item = CleanItem(url: URL(fileURLWithPath: "/fixture/cache"), size: 4096)
    for rule in PreviewRuleCatalog.rules {
      let scans = [
        RuleScan(rule: rule, items: [], skippedCount: 0, blocked: nil),
        RuleScan(rule: rule, items: [item], skippedCount: 0, blocked: nil),
        RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .appRunning("Fixture")),
        RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .needsFullDiskAccess),
        RuleScan(
          rule: rule, items: [], skippedCount: 1, blocked: nil,
          unreadableCount: 1, interruption: .timeLimit),
      ]
      controller.showPreview(
        scans,
        applications: CacheApplicationInventory(
          rules: [rule], applications: [], isComplete: true))
      #expect(scans.allSatisfy { !controller.shouldDisplay($0) })
      #expect(!controller.needsFullDiskAccess && !controller.hasIncompleteScan)
      #expect(controller.totalBytes == 0 && controller.selectedScans.isEmpty)
    }
    // 可清理规则的权限与不完整状态仍需告知用户，不能一起隐藏。
    let rule = try #require(RuleCatalog.rules().first { $0.id == "system.caches" })
    let scan = RuleScan(
      rule: rule, items: [], skippedCount: 0, blocked: .needsFullDiskAccess,
      unreadableCount: 1)
    controller.showPreview([scan])
    #expect(controller.shouldDisplay(scan))
    #expect(controller.needsFullDiskAccess && controller.hasIncompleteScan)
  }
}
