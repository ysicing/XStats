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

  @Test func providerOrderPersistsAndOldDocumentsKeepTheCurrentOrder() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.orderedAIMenuBarProviders == ["claude", "codex", "grok", "gemini"])
    settings.aiMenuBarProviders = ["codex", "claude", "workbuddy", "workbuddy-ai"]
    let order = ["workbuddy-ai", "claude", "workbuddy", "codex"]
    #expect(settings.setAIMenuBarProviderOrder(order))
    #expect(AppSettings(defaults: defaults).orderedAIMenuBarProviders == order)
    #expect(!settings.setAIMenuBarProviderOrder(["claude", "claude", "workbuddy", "codex"]))
    #expect(!settings.setAIMenuBarProviderOrder(["claude"]))
    #expect(settings.orderedAIMenuBarProviders == order)
    settings.aiMenuBarProviders.remove("claude")
    #expect(settings.orderedAIMenuBarProviders == ["workbuddy-ai", "workbuddy", "codex"])
    settings.aiMenuBarProviders.insert("claude")
    #expect(settings.orderedAIMenuBarProviders == order)
    let encoded = try JSONEncoder().encode(settings.exportDocument())
    let decoded = try JSONDecoder().decode(SettingsDocument.self, from: encoded)
    #expect(decoded.aiMenuBarProviderOrder == settings.completeAIMenuBarProviderOrder)
    #expect(
      decoded.aiMenuBarProviderOrder?.filter { settings.aiMenuBarProviders.contains($0) } == order)
    settings.setAIMenuBarProviderOrder(Array(order.reversed()))
    var imported = SettingsDocument()
    imported.aiMenuBarProviders = decoded.aiMenuBarProviders
    imported.aiMenuBarProviderOrder = decoded.aiMenuBarProviderOrder
    settings.apply(imported)
    #expect(settings.orderedAIMenuBarProviders == order)
    settings.apply(SettingsDocument())
    #expect(settings.orderedAIMenuBarProviders == order)
    // 旧备份只保存选中项，同样能恢复；缺项、重复或空服务键均不覆盖。
    imported.aiMenuBarProviderOrder = order
    settings.apply(imported)
    #expect(settings.orderedAIMenuBarProviders == order)
    for invalid in [
      ["claude"], ["claude", "claude", "workbuddy", "codex"],
      order + [""],
    ] {
      imported.aiMenuBarProviderOrder = invalid
      settings.apply(imported)
      #expect(settings.orderedAIMenuBarProviders == order)
    }
    settings.aiMenuBarProviders = []
    #expect(settings.orderedAIMenuBarProviders.isEmpty)
    #expect(AppSettings(defaults: defaults).orderedAIMenuBarProviders.isEmpty)
  }

  @Test func providerDragIsOnlyAPreviewAndRejectsChangedSelections() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    let original = settings.orderedAIMenuBarProviders
    var draft = AIQuotaProviderDrag(provider: "grok", order: original)
    draft.move(over: "claude")
    #expect(draft.previewOrder == ["grok", "claude", "codex", "gemini"])
    #expect(AppSettings(defaults: defaults).orderedAIMenuBarProviders == original)
    #expect(draft.orderToCommit(current: original) == draft.previewOrder)
    #expect(draft.orderToCommit(current: ["codex", "claude"]) == nil)
    draft.move(over: "unselected")
    #expect(draft.previewOrder == ["grok", "claude", "codex", "gemini"])
    draft.move(over: "codex")
    #expect(draft.previewOrder == original)
    defaults.set(["grok", "grok", "unselected", "claude"], forKey: "aiMenuBarProviderOrder")
    #expect(
      AppSettings(defaults: defaults).orderedAIMenuBarProviders
        == ["grok", "claude", "codex", "gemini"])
  }

  @Test func hiddenProviderKeepsItsSlotAfterReorderingAndBackupRestore() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    settings.aiMenuBarProviders = ["claude", "codex", "kimi"]
    #expect(settings.setAIMenuBarProviderOrder(["claude", "codex", "kimi"]))
    settings.aiMenuBarProviders.remove("codex")
    #expect(settings.setAIMenuBarProviderOrder(["kimi", "claude"]))
    let decoded = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    #expect(decoded.aiMenuBarProviderOrder?.contains("codex") == true)
    let restarted = AppSettings(defaults: defaults)
    restarted.aiMenuBarProviders.insert("codex")
    #expect(restarted.orderedAIMenuBarProviders == ["kimi", "codex", "claude"])
    let backupName = "\(name).backup"
    let backupDefaults = try #require(UserDefaults(suiteName: backupName))
    defer { backupDefaults.removePersistentDomain(forName: backupName) }
    let restored = AppSettings(defaults: backupDefaults)
    // 只恢复本用例的字段，避免语言等全局偏好干扰其他用例。
    var imported = SettingsDocument()
    imported.aiMenuBarProviders = decoded.aiMenuBarProviders
    imported.aiMenuBarProviderOrder = decoded.aiMenuBarProviderOrder
    restored.apply(imported)
    #expect(restored.aiMenuBarProviders == ["kimi", "claude"])
    restored.aiMenuBarProviders.insert("codex")
    #expect(restored.orderedAIMenuBarProviders == ["kimi", "codex", "claude"])
    // 全部隐藏后导出仍保留顺序，再恢复显示时不能落回品牌默认顺序。
    restored.aiMenuBarProviders = []
    let hiddenExport = restored.exportDocument()
    var hidden = SettingsDocument()
    hidden.aiMenuBarProviders = hiddenExport.aiMenuBarProviders
    hidden.aiMenuBarProviderOrder = hiddenExport.aiMenuBarProviderOrder
    restored.aiMenuBarProviders = ["claude", "codex", "kimi"]
    #expect(restored.setAIMenuBarProviderOrder(["claude", "codex", "kimi"]))
    restored.apply(hidden)
    #expect(restored.aiMenuBarProviders.isEmpty)
    restored.aiMenuBarProviders = ["claude", "codex", "kimi"]
    #expect(restored.orderedAIMenuBarProviders == ["kimi", "codex", "claude"])
  }

  @Test func hiddenDefaultProviderKeepsItsSlotBeforeTheFirstCustomOrder() throws {
    let name = "AIUsageSettingsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    settings.aiMenuBarProviders.remove("codex")
    #expect(settings.setAIMenuBarProviderOrder(["gemini", "grok", "claude"]))
    settings.aiMenuBarProviders.insert("codex")
    #expect(settings.orderedAIMenuBarProviders == ["gemini", "codex", "grok", "claude"])
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
