// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct SyncScheduleTests {
  @Test(arguments: ["iCloud", "webDAV", "googleDrive", nil] as [String?])
  func participationRequiresExplicitOptInRegardlessOfDestination(savedProvider: String?) throws {
    let suite = "ActivitySyncFeatureTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(savedProvider, forKey: "activity.sync.provider")
    let store = ActivityStore(url: nil)
    let deviceID = UUID()
    let controller = ActivitySyncController(store: store, deviceID: deviceID, defaults: defaults)

    let expectedProvider = savedProvider ?? "iCloud"
    #expect(
      Set(ActivitySyncProvider.allCases.map(\.rawValue)) == ["iCloud", "webDAV", "googleDrive"])
    #expect(controller.provider.rawValue == expectedProvider)
    #expect(!controller.enabled)
    #expect(controller.syncMode == nil)

    controller.setEnabled(true)
    let reopened = ActivitySyncController(store: store, deviceID: deviceID, defaults: defaults)
    #expect(reopened.provider.rawValue == expectedProvider)
    #expect(reopened.enabled)
  }

  @Test(arguments: [5, 10, 30, 60, 0])
  func configuredIntervalPersists(minutes: Int) throws {
    let suite = "ActivitySyncIntervalTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ActivityStore(url: nil)
    let deviceID = UUID()
    let controller = ActivitySyncController(store: store, deviceID: deviceID, defaults: defaults)
    controller.setIntervalMinutes(minutes == 5 ? 10 : 5)
    controller.setIntervalMinutes(minutes)

    #expect(controller.intervalMinutes == minutes)
    let reopened = ActivitySyncController(store: store, deviceID: deviceID, defaults: defaults)
    #expect(reopened.intervalMinutes == minutes)
  }

  @Test func optionalFeatureRegistersThisMacWithoutOptingIntoActivityOrPreferences() async throws {
    let suite = "ActivitySyncEmptyQueueTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let repository = ScheduleRepository()
    let controller = ActivitySyncController(
      store: ActivityStore(url: nil), deviceID: UUID(), defaults: defaults,
      repository: repository, settings: AppSettings(defaults: defaults),
      deviceName: "Lab (Mac mini)")
    defer { controller.setSession(available: false, recordsActivity: false) }

    controller.setIntervalMinutes(5)
    controller.setSession(available: true, recordsActivity: false)
    try await waitUntilIdle(controller)

    #expect(await repository.accessCount == 0)
    controller.setEnabled(true)
    try #require(controller.syncMode == .automatic)
    try await waitUntilIdle(controller)
    let preferences = try #require(controller.preferences)
    #expect(!preferences.isEnabled)
    #expect(preferences.devices.map(\.name) == ["Lab (Mac mini)"])
    #expect(preferences.lastSettingsSyncAt == nil)
    #expect(await repository.publishedActivityCount == 0)
    #expect(await repository.publishedSettingsCount == 1)
    controller.setEnabled(false)
    let accesses = await repository.accessCount
    controller.syncNow()
    #expect(controller.syncMode == nil)
    #expect(await repository.accessCount == accesses)
  }

  @Test(arguments: [false, true])
  func recordingOnANewMacRegistersEvenIfActivityImportFails(corruptActivity: Bool) async throws {
    let suite = "ActivitySyncNewMacTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let repository = ScheduleRepository()
    let source = ActivityStore(url: nil)
    let destination = ActivityStore(url: nil)
    let sourceID = UUID()
    let destinationID = UUID()
    let start = Date(timeIntervalSince1970: 1_750_000_000)
    let row = ActivitySession(
      id: UUID(), deviceID: sourceID, appID: "demo.editor", appName: "Editor", category: "work",
      start: start, end: start.addingTimeInterval(60))
    let controller = ActivitySyncController(
      store: destination, deviceID: destinationID, defaults: defaults, repository: repository,
      settings: AppSettings(defaults: defaults))
    defer { controller.setSession(available: false, recordsActivity: false) }
    let recoveryCode = try await controller.recoveryCode()
    let key = try ActivityKeys.decode(recoveryCode)
    try await source.insert([row])
    try await ActivitySyncEngine(key: key).run(
      store: source, device: sourceID, repository: repository, mode: .manual)
    try #require(await repository.publishedActivityCount == 1)
    await repository.setCorruptActivity(corruptActivity)

    let interval = DateInterval(start: start, duration: 120)
    #expect(try await destination.sessions(in: interval).isEmpty)
    controller.setSession(available: true, recordsActivity: true)
    controller.setEnabled(true)
    try #require(controller.syncMode == .automatic)
    try await waitUntilIdle(controller)

    let preferences = try #require(controller.preferences)
    #expect(!preferences.isEnabled)
    #expect(await repository.publishedSettingsCount == 1)
    let device = try #require(preferences.devices.first { $0.id == destinationID })
    if corruptActivity {
      #expect(device.lastActivitySyncAt == nil)
      let failure = try #require(controller.message)
      #expect(try await destination.sessions(in: interval).isEmpty)
      await repository.setCorruptActivity(false)
      controller.syncNow()
      try await waitUntilIdle(controller)
      #expect(controller.message != failure)
    }

    #expect(try await destination.sessions(in: interval) == [row])
    #expect(preferences.devices.first { $0.id == destinationID }?.lastActivitySyncAt != nil)
  }

  @Test func preferencesOnlySyncInitializesAndWaitsForTheSecondMacsChoice() async throws {
    let firstSuite = "ActivitySyncFirstMac.\(UUID())"
    let secondSuite = "ActivitySyncSecondMac.\(UUID())"
    let firstDefaults = try #require(UserDefaults(suiteName: firstSuite))
    let secondDefaults = try #require(UserDefaults(suiteName: secondSuite))
    defer {
      firstDefaults.removePersistentDomain(forName: firstSuite)
      secondDefaults.removePersistentDomain(forName: secondSuite)
    }

    let firstSettings = AppSettings(defaults: firstDefaults)
    let secondSettings = AppSettings(defaults: secondDefaults)
    firstSettings.appearance = .dark
    secondSettings.appearance = .light
    let firstID = UUID()
    let secondID = UUID()
    let repository = ScheduleRepository()
    let first = ActivitySyncController(
      store: ActivityStore(url: nil), deviceID: firstID, defaults: firstDefaults,
      repository: repository, settings: firstSettings)
    let second = ActivitySyncController(
      store: ActivityStore(url: nil), deviceID: secondID, defaults: secondDefaults,
      repository: repository, settings: secondSettings)
    defer {
      second.setSession(available: false, recordsActivity: false)
      first.setSession(available: false, recordsActivity: false)
    }

    first.setEnabled(true)
    await first.preparePreferences()
    let firstPreferences = try #require(first.preferences)
    #expect(await repository.accessCount == 0)
    try firstPreferences.setEnabled(true)
    first.setSession(available: true, recordsActivity: false)
    try await waitUntilIdle(first)
    try #require(firstPreferences.lastSettingsSyncAt != nil)
    #expect(firstPreferences.firstChoice == nil)
    #expect(await repository.publishedSettingsCount == 1)

    let recoveryCode = try await first.recoveryCode()
    try await second.importRecoveryCode(recoveryCode)
    second.setEnabled(true)
    await second.preparePreferences()
    let secondPreferences = try #require(second.preferences)
    try secondPreferences.setEnabled(true)
    second.setSession(available: true, recordsActivity: false)
    try await waitUntilIdle(second)

    let choice = try #require(secondPreferences.firstChoice)
    #expect(choice.fields.map(\.field) == [.appearance])
    #expect(secondSettings.appearance == .light)
    #expect(secondPreferences.lastSettingsSyncAt == nil)
    #expect(await repository.publishedSettingsCount == 2)
    #expect(secondPreferences.devices.contains { $0.id == secondID })
    try secondPreferences.acceptFirst(choice, selections: [.appearance: .device(firstID)])
    try await waitUntilIdle(second)

    #expect(secondSettings.appearance == .dark)
    #expect(secondPreferences.firstChoice == nil)
    #expect(secondPreferences.lastSettingsSyncAt != nil)
    #expect(await repository.publishedSettingsCount == 2)
    #expect(await repository.publishedActivityCount == 0)

    let marker = await repository.read([ActivitySyncRemotePath.marker])
    let originalMarker = try #require(marker)
    let cipher = ActivitySyncCipher(key: try ActivityKeys.decode(recoveryCode))
    let replacement = try cipher.makeMarker()
    try #require(replacement != originalMarker)
    await repository.replaceMarker(replacement)

    firstSettings.appearance = .light
    first.syncNow()
    try await waitUntilIdle(first)
    try #require(firstPreferences.isEnabled)
    #expect(secondSettings.appearance == .dark)

    second.syncNow()
    try await waitUntilIdle(second)
    #expect(secondPreferences.isEnabled)
    #expect(secondPreferences.firstChoice == nil)
    #expect(secondPreferences.conflicts.isEmpty)
    #expect(secondSettings.appearance == .light)
  }

  @Test func manualOnlySyncRespectsTheToggleAndSessionBeforePublishing() async throws {
    let suite = "ActivitySyncManualScheduleTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let repository = ScheduleRepository()
    let store = ActivityStore(url: nil)
    let deviceID = UUID()
    let start = Date(timeIntervalSince1970: 1_750_000_000)
    let row = ActivitySession(
      id: UUID(), deviceID: deviceID, appID: "demo.editor", appName: "Editor", category: "work",
      start: start, end: start.addingTimeInterval(60))
    try await store.insert([row])
    let controller = ActivitySyncController(
      store: store, deviceID: deviceID, defaults: defaults, repository: repository)
    defer { controller.setSession(available: false, recordsActivity: false) }

    controller.setIntervalMinutes(0)
    controller.setEnabled(false)
    controller.setSession(available: true, recordsActivity: true)
    controller.syncNow()
    #expect(controller.syncMode == nil)

    controller.setSession(available: false, recordsActivity: true)
    controller.setEnabled(true)
    controller.syncNow()
    #expect(controller.syncMode == nil)

    controller.setSession(available: true, recordsActivity: true)
    #expect(controller.syncMode == nil)
    #expect(await repository.accessCount == 0)

    controller.syncNow()
    try #require(controller.syncMode == .manual)
    try await waitUntilIdle(controller)
    #expect(await repository.publishedActivityCount == 1)
  }

  @Test(arguments: ["zh_CN", "de_DE", "ar_SA"])
  func nativeSyncSettingsRenderWithIsolatedPreferences(localeID: String) async throws {
    _ = NSApplication.shared
    let suite = "ActivitySyncPreviewTests.\(UUID())"
    let remoteSuite = "ActivitySyncPreviewRemoteTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let remoteDefaults = try #require(UserDefaults(suiteName: remoteSuite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      remoteDefaults.removePersistentDomain(forName: remoteSuite)
    }
    let localName = "书房 (MacBook Air)"
    let settings = AppSettings(defaults: defaults)
    settings.appearance = .light
    settings.menuBarLayout = .separate
    settings.restSound = .rain
    settings.restEnabled = false
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: nil, networkCacheDefaults: defaults,
      fanControl: nil, activityDeviceName: localName)
    let controller = model.activity.sync
    controller.setEnabled(true)
    await controller.preparePreferences()
    let preferences = try #require(controller.preferences)
    #expect(model.activity.deviceName == localName)
    #expect(controller.intervalMinutes == 10)
    #expect(preferences.isEnabled == false)

    let remoteSettings = AppSettings(defaults: remoteDefaults)
    remoteSettings.appearance = .dark
    remoteSettings.menuBarLayout = .combined
    remoteSettings.restSound = .stream
    remoteSettings.restEnabled = true
    let remoteName =
      switch localeID {
      case "de_DE": "Gemeinsames Arbeitszimmer und Familiencomputer (Mac mini)"
      case "ar_SA": "غرفة المعيشة والمكتب المنزلي المشترك (Mac mini)"
      default: "客厅 (Mac mini)"
      }
    let remote = SyncPreferences(
      settings: remoteSettings, deviceID: UUID(), deviceName: remoteName, defaults: remoteDefaults)
    try remote.selectDestination("sync-preview", key: SymmetricKey(size: .bits256))
    try remote.setEnabled(true)
    let lastActivity = Date(timeIntervalSince1970: 1_750_000_000)
    let prepared = try remote.prepare([:], activitySyncedAt: lastActivity)
    let document = try #require(prepared)
    var documents = [remote.deviceID: document]
    try remote.didPublish(documents)
    let registration = try preferences.prepare(documents, activitySyncedAt: nil)
    let registrationBytes = try #require(registration)
    documents[preferences.deviceID] = registrationBytes
    try preferences.didPublish(documents)
    let devices = SyncSettingsPage.devices(
      preferences.devices, localID: model.activity.deviceID, localName: model.activity.deviceName,
      lastSettingsSyncAt: preferences.lastSettingsSyncAt)
    #expect(devices.map(\.name) == [localName, remoteName])
    #expect(devices.last?.lastActivitySyncAt == lastActivity)

    let page = SyncSettingsPage().environment(model)
    let locale = Locale(identifier: localeID)
    let layoutDirection: LayoutDirection = localeID == "ar_SA" ? .rightToLeft : .leftToRight
    let pageName = localeID == "zh_CN" ? "sync-settings-automatic" : "sync-settings-\(localeID)"
    try renderSyncPreview(
      page, locale: locale, layoutDirection: layoutDirection, name: pageName)

    if localeID == "zh_CN" {
      model.featureSettingsTab = .optional
      try renderSyncPreview(
        FeatureSettings().environment(model), locale: locale, layoutDirection: layoutDirection,
        name: "sync-optional-features")
      controller.setIntervalMinutes(0)
      try renderSyncPreview(
        page, locale: locale, layoutDirection: layoutDirection, name: "sync-settings-manual")
      controller.setEnabled(false)
      controller.setIntervalMinutes(10)
      try renderSyncPreview(
        page, locale: locale, layoutDirection: layoutDirection, name: "sync-settings-disabled")
      controller.setEnabled(true)
    }

    try preferences.setEnabled(true)
    let pendingUpload = try preferences.prepare(documents, activitySyncedAt: nil)
    #expect(pendingUpload == nil)
    let choice = try #require(preferences.firstChoice)
    #expect(Set(choice.fields.map(\.field)) == Set(SyncPreferences.Field.allCases))
    #expect(controller.syncMode == nil)
    try renderSyncPreview(
      SyncPreferenceSettings(preferences: preferences, sync: controller, settings: settings),
      locale: locale, layoutDirection: layoutDirection,
      name: "sync-settings-first-choice-\(localeID)")
  }

  private func renderSyncPreview<Content: View>(
    _ content: Content, locale: Locale, layoutDirection: LayoutDirection, name: String
  ) throws {
    let size = NSSize(width: 640, height: 580)
    let host = NSHostingView(
      rootView:
        content
        .environment(\.locale, locale)
        .environment(\.layoutDirection, layoutDirection)
        .environment(\.isSnapshot, true)
        .environment(\.colorScheme, .light)
        .frame(width: size.width, height: size.height)
        .background(DS.Palette.background))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    #expect(bitmap.pixelsWide >= Int(size.width))
    #expect(bitmap.pixelsHigh >= Int(size.height))

    if let path = ProcessInfo.processInfo.environment["XSTATS_ACTIVITY_PREVIEW_DIR"],
      !path.isEmpty
    {
      let folder = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: folder.appendingPathComponent("\(name).png"), options: .atomic)
    }
  }

  private func waitUntilIdle(_ controller: ActivitySyncController) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while controller.syncing, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(controller.syncing == false)
  }
}

private actor ScheduleRepository: ActivitySyncRepository {
  private var files: [[String]: Data] = [:]
  private var corruptActivity = false
  private(set) var accessCount = 0
  var publishedActivityCount: Int { files.keys.filter { $0.count == 3 }.count }
  var publishedSettingsCount: Int {
    files.keys.filter(ActivitySyncRemotePath.validMetadataObject).count
  }

  func list(_ path: [String]) -> Set<String> {
    accessCount += 1
    return Set(
      files.keys.compactMap { key in
        key.count > path.count && key.starts(with: path) ? key[path.count] : nil
      })
  }

  func read(_ path: [String]) -> Data? {
    accessCount += 1
    if corruptActivity, path.count == 3, files[path] != nil { return Data() }
    return files[path]
  }

  func setCorruptActivity(_ value: Bool) {
    corruptActivity = value
  }

  func replaceMarker(_ data: Data) {
    files[[ActivitySyncRemotePath.marker]] = data
  }

  func create(_ data: Data, at path: [String]) -> Bool {
    accessCount += 1
    guard files[path] == nil else { return false }
    files[path] = data
    return true
  }

  func replaceMetadata(_ data: Data, at path: [String]) {
    accessCount += 1
    files[path] = data
  }
}
