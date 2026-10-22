// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner
@testable import XStatsUI

@MainActor
struct UninstallerFeatureTests {
  @Test func baseFeatureRoutesIgnoreLegacyBackupOptOut() throws {
    let suite = "UninstallerFeatureTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.panelTab = .uninstaller
    #expect(settings.panelTab == .uninstaller)
    #expect(AppDeepLink.page(.uninstaller, settings: settings) == .uninstaller)
    let legacy = try JSONDecoder().decode(
      SettingsDocument.self, from: Data(#"{"uninstallerEnabled":false}"#.utf8))
    #expect(legacy.uninstallerEnabled == false)
    settings.appServicesSection = .homebrew
    settings.apply(legacy)
    #expect(settings.panelTab == .uninstaller && settings.appServicesSection == .homebrew)
    let exported = try JSONEncoder().encode(settings.exportDocument())
    let fields = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
    #expect(fields["uninstallerEnabled"] == nil)
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(settings.panelTab == .uninstaller && settings.appServicesSection == .homebrew)
    #expect(AppSettings(defaults: defaults).appServicesSection == .homebrew)
  }

  @Test func freshAndUpgradedInstallsKeepApplicationServicesAvailable() throws {
    let upgraded = "UninstallerFeatureTests.upgraded.\(UUID())"
    let previous = try #require(UserDefaults(suiteName: upgraded))
    defer { previous.removePersistentDomain(forName: upgraded) }
    // 模拟 0.15.0 的已有偏好：卸载页曾经可用且没有开关键。
    previous.set(PanelTab.uninstaller.rawValue, forKey: "panelTab")
    let migrated = AppSettings(defaults: previous)
    #expect(migrated.panelTab == .uninstaller)

    let fresh = "UninstallerFeatureTests.fresh.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: fresh))
    defer { defaults.removePersistentDomain(forName: fresh) }
    let initial = AppSettings(defaults: defaults)
    initial.panelTab = .uninstaller
    #expect(initial.appServicesSection == .apps)
    defaults.set(false, forKey: "uninstallerEnabled")
    defaults.set(true, forKey: "SUHasLaunchedBefore")
    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.panelTab == .uninstaller && reloaded.appServicesSection == .apps)
    let model = AppModel(
      settings: reloaded, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    defer {
      model.uninstaller.setEnabled(false)
      model.appManagement.setVisible(false)
    }
    #expect(model.uninstaller.enabled)
    #expect(!model.uninstaller.isLoading && !model.appManagement.isReading)
    model.applyMonitoringSettings()
    #expect(model.uninstaller.enabled)
  }

  @Test func disabledControllerDoesNotScanOrRemove() async {
    let controller = UninstallerController(
      currentBundleIdentifier: nil, enabled: false,
      listApplications: {
        Issue.record("Disabled listing")
        return []
      },
      findLeftovers: { _ in
        Issue.record("Disabled leftovers")
        return []
      },
      recycleFiles: { _, _ in Issue.record("Disabled removal") })
    let app = target()
    controller.loadApps()
    controller.reloadApps()
    controller.resumeScanning()
    controller.select(app)
    controller.select(url: app.url)
    controller.quit(app)
    controller.requestUninstall()
    controller.confirmUninstall()
    await Task.yield()
    #expect(controller.apps.isEmpty && controller.selected == nil)
    #expect(!controller.isLoading && !controller.isScanning && !controller.isRemoving)
    #expect(!controller.canUninstall && controller.pendingUninstall == nil)
  }

  @Test func disablingInvalidatesConfirmationAndReenablingRequiresFreshScan() async throws {
    let controller = UninstallerController(
      currentBundleIdentifier: nil,
      findLeftovers: { [AppLeftover(url: $0.url, kind: .application, size: 1)] },
      recycleFiles: { _, _ in Issue.record("Cancelled confirmation recycled files") })
    controller.select(target())
    let deadline = ContinuousClock.now + .seconds(120)
    while controller.isScanning, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(controller.canUninstall)
    controller.requestUninstall()
    try #require(controller.pendingUninstall != nil)
    controller.setEnabled(false)
    controller.confirmUninstall()
    #expect(controller.pendingUninstall == nil && controller.selected == nil)
    #expect(controller.leftovers.isEmpty && controller.chosen.isEmpty)
    controller.setEnabled(true)
    #expect(!controller.canUninstall)
    controller.cancelScanning()
  }

  private func target() -> InstalledApp {
    InstalledApp(
      url: URL(fileURLWithPath: "/Applications/OptionalFixture.app"), name: "OptionalFixture",
      bundleIdentifier: "test.optional.fixture", version: nil, teamIdentifier: nil)
  }
}
