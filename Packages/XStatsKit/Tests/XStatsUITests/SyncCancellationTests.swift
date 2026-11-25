// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct SyncCancellationTests {
  @Test func stoppingThisMacRevokesUnfinishedChoiceWithoutDisablingSettingsIntent() async throws {
    let localSuite = "SyncCancellation.local.\(UUID())"
    let remoteSuite = "SyncCancellation.remote.\(UUID())"
    let localDefaults = try #require(UserDefaults(suiteName: localSuite))
    let remoteDefaults = try #require(UserDefaults(suiteName: remoteSuite))
    defer {
      localDefaults.removePersistentDomain(forName: localSuite)
      remoteDefaults.removePersistentDomain(forName: remoteSuite)
    }
    let settings = AppSettings(defaults: localDefaults)
    settings.appearance = .light
    let controller = ActivitySyncController(
      store: ActivityStore(url: nil), deviceID: UUID(), defaults: localDefaults, settings: settings)
    controller.setEnabled(true)
    await controller.preparePreferences()
    let preferences = try #require(controller.preferences)
    let remoteSettings = AppSettings(defaults: remoteDefaults)
    remoteSettings.appearance = .dark
    let remote = SyncPreferences(
      settings: remoteSettings, deviceID: UUID(), deviceName: nil, defaults: remoteDefaults)
    try remote.selectDestination("remote", key: SymmetricKey(size: .bits256))
    try remote.setEnabled(true)
    let preparedRemote = try remote.prepare([:], activitySyncedAt: nil)
    let remoteBytes = try #require(preparedRemote)
    var documents = [remote.deviceID: remoteBytes]
    try remote.didPublish(documents)
    try preferences.setEnabled(true)
    let registration = try preferences.prepare(documents, activitySyncedAt: nil)
    let registrationBytes = try #require(registration)
    documents[preferences.deviceID] = registrationBytes
    try preferences.didPublish(documents)
    let choice = try #require(preferences.firstChoice)
    try preferences.acceptFirst(choice, selections: [.appearance: .device(remote.deviceID)])
    let preparedLocal = try preferences.prepare(documents, activitySyncedAt: nil)
    let localBytes = try #require(preparedLocal)

    controller.setEnabled(false)
    #expect(!controller.enabled && preferences.isEnabled)
    documents[preferences.deviceID] = localBytes
    controller.setEnabled(true)
    _ = try preferences.prepare(documents, activitySyncedAt: nil)
    #expect(settings.appearance == .light)
    #expect(preferences.firstChoice != nil)
    #expect(controller.syncMode == nil)
  }
}
