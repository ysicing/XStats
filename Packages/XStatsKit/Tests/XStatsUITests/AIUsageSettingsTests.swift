// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct AIUsageSettingsTests {
  @Test func preferredAccountsAndWidgetStylePersistAndExport() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.aiPreferredAccounts.isEmpty)
    #expect(!settings.aiWidgetShowsResetRing)
    settings.aiPreferredAccounts = ["workbuddy": "account-b"]
    settings.aiWidgetShowsResetRing = true
    let restored = AppSettings(defaults: defaults)
    #expect(restored.aiPreferredAccounts == settings.aiPreferredAccounts)
    #expect(restored.aiWidgetShowsResetRing)
    let document = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    #expect(document.aiPreferredAccounts == ["workbuddy": "account-b"])
    #expect(document.aiWidgetShowsResetRing == true)
    settings.aiPreferredAccounts = [:]
    settings.aiWidgetShowsResetRing = false
    // 只恢复本用例的偏好，避免触及进程全局语言。
    var imported = SettingsDocument()
    imported.aiPreferredAccounts = document.aiPreferredAccounts
    imported.aiWidgetShowsResetRing = document.aiWidgetShowsResetRing
    settings.apply(imported)
    #expect(settings.aiPreferredAccounts == ["workbuddy": "account-b"])
    #expect(settings.aiWidgetShowsResetRing)
    settings.aiPreferredAccounts["workbuddy"] = nil
    #expect(AppSettings(defaults: defaults).aiPreferredAccounts.isEmpty)
  }

  @Test func menuBarProviderChoicesPersistIncludingAnEmptySelection() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.aiMenuBarProviders == ["codex", "claude", "grok", "gemini"])
    // 新装后保存了菜单栏项，再次启动也不能被当作旧版升级。
    settings.menuBarItems.insert(.aiUsage)
    #expect(defaults.stringArray(forKey: "menuBarItems") != nil)
    #expect(AppSettings(defaults: defaults).aiMenuBarProviders == settings.aiMenuBarProviders)
    settings.aiMenuBarProviders = ["copilot", "future-provider"]
    #expect(AppSettings(defaults: defaults).aiMenuBarProviders == settings.aiMenuBarProviders)
    settings.aiMenuBarProviders = []
    #expect(AppSettings(defaults: defaults).aiMenuBarProviders.isEmpty)
  }

  @Test func menuBarProviderLimitAppliesToSavedAndAssignedSelections() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let oversized = ["custom-z", "copilot", "grok", "gemini", "claude", "codex"]
    defaults.set(oversized, forKey: "aiMenuBarProviders")
    let settings = AppSettings(defaults: defaults)
    let expected: Set<String> = ["codex", "claude", "gemini", "grok"]
    #expect(settings.aiMenuBarProviders == expected)
    #expect(Set(try #require(defaults.stringArray(forKey: "aiMenuBarProviders"))) == expected)
    settings.aiMenuBarProviders = ["custom-z", "custom-a", "custom-c", "custom-b", "custom-d"]
    #expect(settings.aiMenuBarProviders == ["custom-a", "custom-b", "custom-c", "custom-d"])
    settings.aiMenuBarProviders = ["copilot", "custom-z", "claude", "perplexity"]
    #expect(AppSettings(defaults: defaults).aiMenuBarProviders == settings.aiMenuBarProviders)
    settings.aiMenuBarProviders.remove("claude")
    settings.aiMenuBarProviders.insert("gemini")
    #expect(settings.aiMenuBarProviders == ["copilot", "custom-z", "gemini", "perplexity"])
  }

  @Test func oldPreferencesKeepDefaultsAndNewChoicesPersist() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.aiQuotaShowsRemaining)
    #expect(!settings.aiUsageWesternUnits)
    #expect(settings.aiUsageRefreshMinutes == 5)
    settings.aiQuotaShowsRemaining = false
    settings.aiUsageWesternUnits = true
    for interval in [1, 3, 5, 10, 15, 30, 60] {
      settings.aiUsageRefreshMinutes = interval
      let restored = AppSettings(defaults: defaults)
      #expect(restored.aiUsageRefreshMinutes == interval)
      #expect(!restored.aiQuotaShowsRemaining)
      #expect(restored.aiUsageWesternUnits)
    }
    defaults.set(0, forKey: "aiUsageRefreshMinutes")
    let repaired = AppSettings(defaults: defaults)
    #expect(repaired.aiUsageRefreshMinutes == 5)
  }
  @Test func navigationExposesAIAsAToolAndMenuBarItem() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(!PanelTab.monitors.contains(.aiUsage))
    #expect(PanelTab.tools.first == .aiUsage)
    #expect(PanelTab(item: .aiUsage) == .aiUsage)
    #expect(
      MenuBarStyle.options(for: .aiUsage) == [
        .stacked, .stackedCenter, .inline, .icon, .ring, .pie, .meter, .dot,
      ])
    let settings = AppSettings(defaults: defaults)
    settings.menuBarStyle = .history
    #expect(settings.style(for: .aiUsage) == .ring)
    settings.menuBarStyle = .line
    #expect(settings.style(for: .aiUsage) == .ring)
    settings.menuBarStyle = .pie
    #expect(settings.style(for: .aiUsage) == .pie)
  }

  @Test func settingsDefaultToOptInAndFiveMinuteRefresh() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)

    #expect(!settings.aiUsageEnabled)
    #expect(settings.aiUsageRefreshMinutes == 5)
  }

  @Test func disablingAIUsageLeavesItsHiddenPageAndRestoresNavigationOnEnable() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)

    settings.aiUsageEnabled = true
    settings.panelTab = .aiUsage
    settings.aiUsageEnabled = false

    #expect(settings.panelTab == .settingsFeatures)
    #expect(AppSettings(defaults: defaults).panelTab == .settingsFeatures)

    settings.aiUsageEnabled = true
    settings.panelTab = .aiUsage
    #expect(settings.panelTab == .aiUsage)
  }

  @Test func disabledAIUsageDoesNotRestoreItsSavedPage() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("aiUsage", forKey: "panelTab")

    #expect(AppSettings(defaults: defaults).panelTab == .settingsFeatures)
  }

  /// 加入菜单栏自动开启模块；移出只停止展示，关闭模块同时移除入口。
  @Test func menuBarSelectionEnablesTheModuleAndDisablingItRemovesTheEntry() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.aiUsageEnabled)

    settings.setEnabled(.aiUsage, true)

    #expect(settings.aiUsageEnabled)
    #expect(settings.isEnabled(.aiUsage))
    #expect(settings.orderedMenuBarItems.contains(.aiUsage))
    settings.setEnabled(.aiUsage, false)
    #expect(settings.aiUsageEnabled)
    settings.setEnabled(.aiUsage, true)

    settings.aiUsageEnabled = true
    #expect(settings.orderedMenuBarItems.contains(.aiUsage))

    settings.aiUsageShowsLocalUsage = false
    #expect(settings.orderedMenuBarItems.contains(.aiUsage))

    settings.aiUsageEnabled = false
    #expect(!settings.menuBarItems.contains(.aiUsage))
    #expect(!settings.isEnabled(.aiUsage))
    #expect(!settings.orderedMenuBarItems.contains(.aiUsage))
  }

}
