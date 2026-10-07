// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner
@testable import XStatsUI

@MainActor
struct UninstallerFeatureTests {
    @Test func defaultOffRoutesAndBackupRestore() throws {
        let suite = "UninstallerFeatureTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PanelTab.uninstaller.rawValue, forKey: "panelTab")
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.uninstallerEnabled)
        #expect(settings.panelTab == .settingsFeatures)
        settings.panelTab = .uninstaller
        #expect(settings.panelTab == .settingsFeatures)
        #expect(AppDeepLink.page(.uninstaller, settings: settings) == .settingsFeatures)
        settings.uninstallerEnabled = true
        settings.panelTab = .uninstaller
        #expect(settings.panelTab == .uninstaller)
        #expect(AppDeepLink.page(.uninstaller, settings: settings) == .uninstaller)
        let saved = try JSONDecoder().decode(SettingsDocument.self,
                                            from: JSONEncoder().encode(settings.exportDocument()))
        settings.uninstallerEnabled = false
        #expect(settings.panelTab == .settingsFeatures)
        settings.apply(saved)
        #expect(settings.uninstallerEnabled)
        settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
        #expect(settings.uninstallerEnabled)
        #expect(AppSettings(defaults: defaults).uninstallerEnabled)
    }

    @Test func disabledControllerDoesNotScanOrRemove() async {
        let controller = UninstallerController(currentBundleIdentifier: nil, enabled: false,
            listApplications: { Issue.record("Disabled listing"); return [] },
            findLeftovers: { _ in Issue.record("Disabled leftovers"); return [] },
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
        let controller = UninstallerController(currentBundleIdentifier: nil,
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
        InstalledApp(url: URL(fileURLWithPath: "/Applications/OptionalFixture.app"), name: "OptionalFixture",
                     bundleIdentifier: "test.optional.fixture", version: nil, teamIdentifier: nil)
    }
}
