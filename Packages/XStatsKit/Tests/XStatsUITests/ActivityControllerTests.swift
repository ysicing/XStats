// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import XStatsUI

struct ActivityControllerTests {
  @MainActor @Test func experimentalGateControlsRecordingAndNavigationTogether() throws {
    let suite = "ActivityFeatureTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("activity", forKey: "panelTab")
    defaults.set(true, forKey: "activity.recording")
    let settings = AppSettings(defaults: defaults)
    let model = AppModel(settings: settings, historyURL: nil)
    #expect(!settings.activityFeatureEnabled && !model.activity.enabled)
    #expect(settings.panelTab == .settingsFeatures)
    #expect(AppDeepLink.page(.activity, settings: settings) == .settingsFeatures)
    model.setActivityFeatureEnabled(true)
    #expect(AppDeepLink.page(.activity, settings: settings) == .activity)
    #expect(model.activity.enabled && !model.activity.sync.active)
    settings.panelTab = .activity
    #expect(AppSettings(defaults: defaults).panelTab == .activity)
    #expect(AppModel(settings: AppSettings(defaults: defaults), historyURL: nil).activity.enabled)
    model.setActivityFeatureEnabled(false)
    #expect(!model.activity.enabled && !defaults.bool(forKey: "activity.enabled"))
    #expect(settings.panelTab == .settingsFeatures)
    settings.panelTab = .activity
    #expect(settings.panelTab == .settingsFeatures)
    #expect(!AppSettings(defaults: defaults).activityFeatureEnabled)
    model.setActivityFeatureEnabled(true)
    settings.panelTab = .activity
    model.activity.setEnabled(false)
    #expect(!settings.activityFeatureEnabled && settings.panelTab == .settingsFeatures)
  }

  @MainActor @Test(arguments: [true, false], [true, false, nil] as [Bool?])
  func upgradePreservesRecordingConsent(feature: Bool, recording: Bool?) throws {
    let suite = "ActivityFeatureMigrationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(feature, forKey: "activity.featureEnabled")
    defaults.set(recording, forKey: "activity.recording")
    let settings = AppSettings(defaults: defaults)
    let model = AppModel(settings: settings, historyURL: nil)
    let wasRecording = feature && recording == true
    #expect(settings.activityFeatureEnabled == wasRecording)
    #expect(model.activity.enabled == wasRecording)
    model.setActivityFeatureEnabled(!wasRecording)
    #expect(AppSettings(defaults: defaults).activityFeatureEnabled == !wasRecording)
  }

  @MainActor @Test func samplingAndSyncFollowRecordingAndSessionLifetime() async throws {
    let suite = "ActivityControllerTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let initial = ActivityController(defaults: defaults, databaseURL: nil)
    #expect(!initial.enabled && initial.sync.provider == .iCloud)
    defaults.set(ActivitySyncProvider.local.rawValue, forKey: "activity.sync.provider")
    var available = true
    let controller = ActivityController(
      defaults: defaults, databaseURL: nil, sessionAvailable: { available })
    #expect(controller.deviceID == initial.deviceID)
    controller.start()
    controller.setPaused(false)
    #expect(!controller.isSampling && !controller.sync.active)
    controller.setEnabled(true)
    for _ in 0..<5 {
      #expect(controller.isSampling && controller.sync.active)
      controller.setPaused(true)
      #expect(!controller.isSampling && !controller.sync.active)
      available = false
      controller.setPaused(false)
      #expect(!controller.isSampling && !controller.sync.active)
      available = true
      controller.setPaused(false)
    }
    controller.setEnabled(false)
    #expect(!controller.isSampling && !controller.sync.active)
    controller.setEnabled(true)
    await controller.stop()
    #expect(!controller.isSampling && !controller.sync.active)
  }

  private let first = ActivityApplication(id: "test.first", name: "Editor", category: "work")
  private let second = ActivityApplication(
    id: "test.second", name: "Game", category: "entertainment")
  private let device = UUID()
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  @MainActor @Test func failedFinalWriteSurvivesUntilStorageRecovers() async throws {
    let suite = "ActivityWriteTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data().write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = ActivityController(
      defaults: defaults, databaseURL: directory.appending(path: "activity.sqlite"))
    let session = ActivitySession(
      id: UUID(), deviceID: controller.deviceID, appID: first.id,
      appName: first.name, category: first.category, start: start, end: start + 30)
    controller.enqueue(session)
    #expect(await controller.stop() == false)
    #expect(controller.writeFailed)
    try FileManager.default.removeItem(at: directory)
    #expect(await controller.stop())
    #expect(
      try await controller.store.sessions(in: DateInterval(start: start, duration: 60)) == [session]
    )
  }

  @Test func idleCutoffAndResumeExcludeTimeAway() throws {
    var clock = ActivityClock()
    #expect(clock.observe(first, at: start, idle: 1, deviceID: device, uptime: 0) == nil)
    let idleSample = clock.observe(first, at: start + 360, idle: 335, deviceID: device, uptime: 360)
    let idle = try #require(idleSample)
    #expect(idle.start == start && idle.end == start + 325)
    #expect(clock.current == nil)
    #expect(clock.observe(first, at: start + 500, idle: 475, deviceID: device, uptime: 500) == nil)
    #expect(clock.observe(first, at: start + 615, idle: 15, deviceID: device, uptime: 615) == nil)
    let lastSample = clock.observe(nil, at: start + 630, idle: 30, deviceID: device, uptime: 630)
    let stopped = try #require(lastSample)
    #expect(stopped.start == start + 600 && stopped.end == start + 630)
    #expect(clock.current == nil)
  }

  @Test func activationsAndCheckpointsKeepOneContinuousInterval() throws {
    var clock = ActivityClock()
    _ = clock.observe(first, at: start, idle: 0, deviceID: device, uptime: 0)
    #expect(clock.observe(first, at: start + 12, idle: 4, deviceID: device, uptime: 12) == nil)
    let checkpointSample = clock.observe(
      first, at: start + 300, idle: 5, deviceID: device, checkpoint: true, uptime: 300)
    let switchSample = clock.observe(
      second, at: start + 310, idle: 1, deviceID: device, uptime: 310)
    let stopSample = clock.observe(nil, at: start + 330, idle: 0, deviceID: device, uptime: 330)
    let checkpoint = try #require(checkpointSample)
    let switched = try #require(switchSample)
    let stopped = try #require(stopSample)
    #expect(checkpoint.end == switched.start && switched.end == stopped.start)
    #expect(
      checkpoint.appID == first.id && switched.appID == first.id && stopped.appID == second.id)
    #expect(Set([checkpoint.id, switched.id, stopped.id]).count == 3)
  }

  @Test func clockAdjustmentOnlyCountsElapsedUsage() throws {
    var clock = ActivityClock()
    _ = clock.observe(first, at: start, idle: 0, deviceID: device, uptime: 100)
    let sample = clock.observe(first, at: start + 3660, idle: 0, deviceID: device, uptime: 160)
    let closed = try #require(sample)
    #expect(closed.end == start + 60)
    #expect(clock.current?.start == start + 3660)
  }

  @Test func classificationsUseBundleIdentityAndDeclaredAppCategory() {
    #expect(ActivityApplication.category(for: "com.apple.Safari", storeCategory: nil) == "browsing")
    #expect(
      ActivityApplication.category(
        for: "test.game", storeCategory: "public.app-category.board-games") == "entertainment")
    #expect(
      ActivityApplication.category(
        for: "test.editor", storeCategory: "public.app-category.productivity") == "work")
    #expect(ActivityApplication.category(for: "test.unknown", storeCategory: nil) == "other")
  }
}
