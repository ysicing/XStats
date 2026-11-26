// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Sparkle
import Testing
import Updates
@testable import XStatsUI

@MainActor
struct UpdateAvailabilityTests {
  @Test(
    arguments: [
      ("work.12306.xstats.app", true),
      ("work.12306.xstats.capture", false),
      ("work.12306.xstats.networkmonitor", false),
      ("com.example.other", false),
      (nil, false),
    ] as [(String?, Bool)])
  func unsignedHostCanUpgradeOnlyTheMainProduct(_ identifier: String?, _ allowed: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let appURL = directory.appendingPathComponent("XStats.app")
    let contents = appURL.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: Any] = [
      "CFBundleName": "XStats", "CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1",
    ]
    info["CFBundleIdentifier"] = identifier
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    let bundle = try #require(Bundle(url: appURL))
    #expect(UpdateInstaller.teamIdentifier(of: appURL) == nil)
    let suite = "UpdateAvailabilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = UpdateController(
      settings: AppSettings(defaults: defaults), defaults: defaults, bundle: bundle)
    #expect((controller.installBlockedReason == nil) == allowed)
    #expect(controller.currentVersion == "0.0.1")
  }

  private func release(_ version: String, build: String = "200") -> UpdateRelease {
    UpdateRelease(
      version: version, build: build, date: "2026-10-05", minimumSystem: "14.0",
      url: URL(string: "https://example.invalid/XStats.zip")!,
      sha256: String(repeating: "a", count: 64),
      size: 1000, dmg: nil, notes: [], changelog: nil)
  }

  private func appBundle(in directory: URL, identifier: String? = "work.12306.xstats.app") throws
    -> Bundle
  {
    let appURL = directory.appendingPathComponent("XStats.app")
    let contents = appURL.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: Any] = [
      "CFBundleName": "XStats", "CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1",
    ]
    info["CFBundleIdentifier"] = identifier
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    return try #require(Bundle(url: appURL))
  }

  private func appcastItem(for release: UpdateRelease) throws -> SUAppcastItem {
    try #require(
      SUAppcastItem(dictionary: [
        "sparkle:version": release.build,
        "sparkle:shortVersionString": release.version,
        "sparkle:minimumSystemVersion": release.minimumSystem,
        "pubDate": "Mon, 05 Oct 2026 00:00:00 +0000",
        "xstats:sha256": release.sha256,
        "enclosure": [
          "url": release.url.absoluteString,
          "length": String(release.size),
          "type": "application/octet-stream",
        ],
      ]))
  }

  private func updateState() throws -> SPUUserUpdateState {
    let archive = NSKeyedArchiver(requiringSecureCoding: true)
    archive.encode(0, forKey: "SPUUserUpdateStateStage")
    archive.encode(true, forKey: "SPUUserUpdateStateUserInitiated")
    archive.finishEncoding()
    let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
    defer { decoder.finishDecoding() }
    return try #require(SPUUserUpdateState(coder: decoder))
  }

  @Test func reopeningKnownReleaseRequestsRefreshWithoutInstalling() throws {
    let suite = "UpdateAvailabilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.notifyUpdates = false
    settings.updateCheckSchedule = .never
    let controller = UpdateController(settings: settings, defaults: defaults)
    var prompts = 0
    controller.onPrompt = { refresh in
      #expect(refresh)
      prompts += 1
    }
    #expect(!controller.hasAvailableUpdate)
    controller.presentAvailableUpdate()
    #expect(prompts == 0)
    controller.showPreview(release("1.0.0"))
    controller.presentAvailableUpdate()
    controller.presentAvailableUpdate()
    #expect(prompts == 2 && controller.hasAvailableUpdate)
    #expect(controller.phase == .available && controller.lastChecked == nil)
    #expect(controller.release?.version == "1.0.0")
  }

  @Test func skippedReleaseStaysHiddenAfterSparkleClearsTheCompatibilityRecord() throws {
    let suite = "UpdateAvailabilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("1.0.0", forKey: "updateSkippedVersion")
    let controller = UpdateController(settings: AppSettings(defaults: defaults), defaults: defaults)
    var prompts = 0
    controller.onPrompt = { _ in prompts += 1 }
    controller.showPreview(release("1.0.0"))
    #expect(!controller.hasAvailableUpdate)
    controller.presentAvailableUpdate()
    #expect(prompts == 0)
    controller.finishSkipMigration()
    #expect(controller.skippedVersion == nil && controller.release == nil)
    #expect(controller.phase == .idle && !controller.isBusy)
    #expect(!controller.hasAvailableUpdate)
    #expect(defaults.string(forKey: "updateSkippedVersion") == nil)
    controller.showPreview(release("1.0.1"))
    #expect(controller.hasAvailableUpdate)
    controller.presentAvailableUpdate()
    #expect(prompts == 1)
  }

  @Test func completingAnOlderSkipPreservesANewerCachedRelease() throws {
    let suite = "UpdateAvailabilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("1.0.0", forKey: "updateSkippedVersion")
    let controller = UpdateController(settings: AppSettings(defaults: defaults), defaults: defaults)
    controller.showPreview(release("1.0.1"))
    controller.finishSkipMigration()
    #expect(controller.release?.version == "1.0.1" && controller.hasAvailableUpdate)
  }

  @Test func supersedingReleaseConfirmationResetsAfterCancelOrSkip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = try appBundle(in: directory)
    let suite = "UpdateAvailabilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var captured: SparkleInstaller?
    let controller = UpdateController(
      settings: AppSettings(defaults: defaults), defaults: defaults, bundle: bundle,
      startUpdater: {
        captured = $0
        return nil
      })
    controller.showPreview(release("1.0.0", build: "200"))
    controller.install()
    let installer = try #require(captured)
    let updater = SPUUpdater(
      hostBundle: bundle, applicationBundle: bundle, userDriver: installer, delegate: installer)
    let state = try updateState()

    let firstReplacement = try appcastItem(for: release("1.0.1", build: "201"))
    try installer.updater(updater, mayPerform: .updates)
    #expect(controller.phase == .checking && !controller.canCloseUpdatePrompt)
    try installer.updater(updater, shouldProceedWithUpdate: firstReplacement, updateCheck: .updates)
    installer.showUpdateFound(with: firstReplacement, state: state) { _ in }
    installer.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
    #expect(
      controller.phase == .available && controller.release?.version == "1.0.1"
        && controller.needsNewConfirmation && controller.canCloseUpdatePrompt)

    controller.install()
    #expect(!controller.needsNewConfirmation)
    installer.showDownloadInitiated {}
    #expect(controller.isDownloading)
    controller.cancel()
    #expect(controller.phase == .available && !controller.needsNewConfirmation)

    let secondReplacement = try appcastItem(for: release("1.0.2", build: "202"))
    controller.install()
    try installer.updater(updater, mayPerform: .updates)
    try installer.updater(
      updater, shouldProceedWithUpdate: secondReplacement, updateCheck: .updates)
    installer.showUpdateFound(with: secondReplacement, state: state) { _ in }
    installer.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
    #expect(controller.needsNewConfirmation)
    controller.skipCurrentRelease()
    #expect(!controller.needsNewConfirmation && !controller.hasAvailableUpdate)
  }

  @Test func promptRefreshClearsStaleOfferAndPreservesFailureAcrossBackgroundChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = try appBundle(in: directory)
    let suite = "UpdateAvailabilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var captured: SparkleInstaller?
    let controller = UpdateController(
      settings: AppSettings(defaults: defaults), defaults: defaults, bundle: bundle,
      startUpdater: {
        captured = $0
        return nil
      })
    controller.showPreview(release("1.0.0", build: "200"))
    controller.refreshOpenPrompt()
    #expect(controller.release == nil && controller.phase == .checking)
    let installer = try #require(captured)
    let updater = SPUUpdater(
      hostBundle: bundle, applicationBundle: bundle, userDriver: installer, delegate: installer)
    let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    for _ in 0..<3 {
      try installer.updater(updater, mayPerform: .updates)
      installer.updater(updater, didFinishUpdateCycleFor: .updates, error: offline)
    }
    #expect(controller.release == nil)
    guard case .failed = controller.phase else {
      Issue.record("Prompt refresh failure must stay visible")
      return
    }

    controller.check(userInitiated: false)
    for _ in 0..<3 {
      try installer.updater(updater, mayPerform: .updatesInBackground)
      installer.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: offline)
    }
    guard case .failed = controller.phase else {
      Issue.record("Background failure must not replace an existing prompt failure with idle")
      return
    }
  }

  @Test func openingPromptDuringSkipRefreshesAfterSkipFinishes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = try appBundle(in: directory)
    let suite = "UpdateAvailabilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var captured: SparkleInstaller?
    let controller = UpdateController(
      settings: AppSettings(defaults: defaults), defaults: defaults, bundle: bundle,
      startUpdater: {
        captured = $0
        return nil
      })
    let skippedRelease = release("1.0.0")
    controller.showPreview(skippedRelease)
    controller.skipCurrentRelease()
    let installer = try #require(captured)
    let updater = SPUUpdater(
      hostBundle: bundle, applicationBundle: bundle, userDriver: installer, delegate: installer)
    try installer.updater(updater, mayPerform: .updates)
    controller.refreshOpenPrompt()
    #expect(controller.release == nil && installer.isSkipping)
    installer.showUpdateFound(
      with: try appcastItem(for: skippedRelease), state: try updateState()
    ) { choice in
      #expect(choice == .skip)
      installer.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
    }
    #expect(!installer.isSkipping && !installer.isBackgroundCheck)
    let replacement = release("1.0.1", build: "201")
    installer.showUpdateFound(
      with: try appcastItem(for: replacement), state: try updateState()
    ) { #expect($0 == .dismiss) }
    #expect(controller.release?.version == replacement.version && controller.phase == .available)
  }

  @Test(arguments: [false, true])
  func promptRefreshStopsAfterManualCheckWithIncompatibleUpdate(reuseBackground: Bool) throws {
    let suite = "UpdateAvailabilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var captured: SparkleInstaller?
    let controller = UpdateController(
      settings: AppSettings(defaults: defaults), defaults: defaults,
      startUpdater: {
        captured = $0
        return nil
      })
    if reuseBackground { controller.check(userInitiated: false) }
    controller.refreshOpenPrompt()
    #expect(controller.canCloseUpdatePrompt)
    let installer = try #require(captured)
    let updater = SPUUpdater(
      hostBundle: .main, applicationBundle: .main, userDriver: installer, delegate: installer)
    let incompatible = NSError(
      domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
      userInfo: [
        SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.systemIsTooNew.rawValue),
        SPULatestAppcastItemFoundKey: try appcastItem(for: release("1.0.1", build: "99999999")),
      ])
    if reuseBackground {
      try installer.updater(updater, mayPerform: .updatesInBackground)
      installer.updaterDidNotFindUpdate(updater, error: incompatible)
      installer.onCycleFinished(true)
      #expect(controller.phase == .checking && !installer.isBackgroundCheck)
    }
    try installer.updater(updater, mayPerform: .updates)
    installer.updaterDidNotFindUpdate(updater, error: incompatible)
    installer.onCycleFinished(true)
    #expect(controller.phase == .idle && controller.release == nil)
  }
}
