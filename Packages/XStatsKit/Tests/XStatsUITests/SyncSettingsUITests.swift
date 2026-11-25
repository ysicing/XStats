// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
import WebDAVSync
@testable import XStatsUI

@MainActor
struct SyncSettingsUITests {
  @Test func deviceIconsReflectTheMacModelRatherThanWhetherItIsLocal() {
    #expect(SyncSettingsPage.deviceIcon("Desk (Mac mini)") == "macmini")
    #expect(SyncSettingsPage.deviceIcon("Work (MacBook Air)") == "laptopcomputer")
    #expect(SyncSettingsPage.deviceIcon(nil) == "desktopcomputer")
  }
  @Test func syncHasItsOwnSettingsEntryAndRouteWhenActivityIsDisabled() throws {
    let suite = "SyncSettingsUITests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(PanelTab.settingsSync.rawValue, forKey: "panelTab")
    let settings = AppSettings(defaults: defaults)

    #expect(!settings.activityFeatureEnabled)
    #expect(settings.panelTab == .settingsSync)
    #expect(PanelTab.settings.filter { $0 == .settingsSync }.count == 1)
    #expect(PanelTab.settingsSync.isSettings)
    #expect(PanelTab.settingsSync.sidebarTab == .settingsSync)
    #expect(AppDeepLink.page(.settingsSync, settings: settings) == .settingsSync)
    let url = try #require(URL(string: "xstats://open/settings/sync"))
    #expect(AppDeepLink(url: url) == .open(.settingsSync))
    let commands = AppCommand.catalog(supportsFans: false)
    #expect(commands.contains { $0.action == .route(.open(.settingsSync)) })

    defaults.set(PanelTab.settingsAccount.rawValue, forKey: "panelTab")
    #expect(AppSettings(defaults: defaults).panelTab == .settingsGeneral)
  }

  @Test func deviceListShowsTheLocalMacOnceAndPreservesVerifiedReceipts() {
    let localID = UUID()
    let remoteID = UUID()
    let activityReceipt = Date(timeIntervalSinceReferenceDate: 10)
    let settingsReceipt = Date(timeIntervalSinceReferenceDate: 20)
    let remote = SyncPreferences.Device(
      id: remoteID, name: "Remote", lastActivitySyncAt: nil, lastSettingsSyncAt: settingsReceipt)
    let local = SyncPreferences.Device(
      id: localID, name: "Old Name", lastActivitySyncAt: activityReceipt, lastSettingsSyncAt: nil)

    let unsynced = SyncSettingsPage.devices(
      [], localID: localID, localName: nil, lastSettingsSyncAt: nil)
    #expect(unsynced.map(\.id) == [localID])
    #expect(unsynced.first?.lastActivitySyncAt == nil)
    #expect(unsynced.first?.lastSettingsSyncAt == nil)

    let synchronized = SyncSettingsPage.devices(
      [remote, local], localID: localID, localName: "This Mac", lastSettingsSyncAt: settingsReceipt)
    #expect(synchronized.map(\.id) == [localID, remoteID])
    #expect(synchronized.first?.name == "This Mac")
    #expect(synchronized.first?.lastActivitySyncAt == activityReceipt)
    #expect(synchronized.first?.lastSettingsSyncAt == settingsReceipt)
    #expect(synchronized.last == remote)
  }

  @Test func legacyBackupAcceptsTheSizeLimitAndRejectsOneExtraByte() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var document = SettingsDocument()
    document.restEnabled = true
    let backup = SettingsBackup(document: document, savedAt: Date(timeIntervalSince1970: 100))
    var data = try backup.encoded()
    data.append(Data(repeating: 0x20, count: WebDAVClient.maximumBytes - data.count))
    try data.write(to: url)
    let loaded = try await SettingsBackup.readLegacyFile(url)
    #expect(loaded == backup)

    data.append(0x20)
    try data.write(to: url)
    await #expect(throws: WebDAVError.tooLarge) { try await SettingsBackup.readLegacyFile(url) }
  }

  @Test func legacyBackupRejectsUnrelatedJSONAndFutureSchemas() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("{}".utf8).write(to: url)
    await #expect(throws: WebDAVError.invalidDocument) {
      try await SettingsBackup.readLegacyFile(url)
    }

    var document = SettingsDocument()
    document.schema = 2
    try SettingsBackup(document: document).encoded().write(to: url)
    await #expect(throws: WebDAVError.unsupportedVersion) {
      try await SettingsBackup.readLegacyFile(url)
    }
  }
}
