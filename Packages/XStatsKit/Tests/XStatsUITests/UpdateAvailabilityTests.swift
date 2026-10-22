// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
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

  private func release(_ version: String) -> UpdateRelease {
    UpdateRelease(
      version: version, build: "200", date: "2026-10-05", minimumSystem: "14.0",
      url: URL(string: "https://example.invalid/XStats.zip")!,
      sha256: String(repeating: "a", count: 64),
      size: 1000, dmg: nil, notes: [], changelog: nil)
  }

  @Test func presentingKnownReleaseKeepsItAvailableWithoutCheckingOrInstalling() throws {
    let suite = "UpdateAvailabilityTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.notifyUpdates = false
    settings.updateCheckSchedule = .never
    let controller = UpdateController(settings: settings, defaults: defaults)
    var prompts = 0
    controller.onPrompt = { prompts += 1 }
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
    controller.onPrompt = { prompts += 1 }
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
}
