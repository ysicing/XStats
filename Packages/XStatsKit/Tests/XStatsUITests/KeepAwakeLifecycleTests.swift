// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
private final class SleepControlFixture: SleepControlClient {
  var requests: [Bool] = []
  var sleepDisabled = false
  var enableContinuation: CheckedContinuation<String?, Never>?
  var restorationError: String?

  func setSleepDisabled(_ disabled: Bool) async -> String? {
    requests.append(disabled)
    if disabled {
      let result = await withCheckedContinuation { enableContinuation = $0 }
      sleepDisabled = true
      return result
    }
    if let restorationError { return restorationError }
    sleepDisabled = false
    return nil
  }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct KeepAwakeLifecycleTests {
  @Test(arguments: [false, true], KeepAwakeController.Mode.allCases.map(\.rawValue))
  func unplugStopsOnlyWhenEnabled(enabled: Bool, rawMode: String) async throws {
    try await withController(stopOnUnplug: enabled) { controller, helper in
      controller.setMode(try #require(KeepAwakeController.Mode(rawValue: rawMode)))
      controller.setDuration(.minutes15)
      await controller.start()
      controller.evaluateBattery(
        BatteryStatus(level: 1, isCharging: false, isPluggedIn: true, isFullyCharged: true))
      let stop = controller.evaluateBattery(
        BatteryStatus(level: 1, isCharging: false, isPluggedIn: false, isFullyCharged: true))
      await stop?.value
      #expect(controller.isActive == !enabled)
      #expect((controller.endDate == nil) == enabled)
      #expect(helper.requests.isEmpty)
    }
  }

  @Test func firstBatteryReadingDoesNotStopAndReplugNeverRestarts() async throws {
    try await withController(stopOnUnplug: true) { controller, _ in
      let plugged = BatteryStatus(
        level: 0.8, isCharging: false, isPluggedIn: true, isFullyCharged: false)
      let battery = BatteryStatus(
        level: 0.8, isCharging: false, isPluggedIn: false, isFullyCharged: false)
      await controller.start()
      #expect(controller.evaluateBattery(nil) == nil)
      #expect(controller.evaluateBattery(battery) == nil)
      #expect(controller.isActive)
      controller.evaluateBattery(plugged)
      controller.evaluateBattery(nil)
      await controller.evaluateBattery(battery)?.value
      #expect(!controller.isActive)
      #expect(controller.evaluateBattery(battery) == nil)
      #expect(controller.evaluateBattery(plugged) == nil)
      #expect(!controller.isActive)
      // 在电池供电时手动开启，不沿用上一会话的接电基线。
      await controller.start()
      #expect(controller.evaluateBattery(battery) == nil)
      #expect(controller.isActive)
    }
  }

  @Test func queuedRestorationDoesNotStopANewManualSession() async throws {
    try await withController(stopOnUnplug: true) { controller, _ in
      await controller.start()
      controller.evaluateBattery(
        BatteryStatus(level: 0.8, isCharging: false, isPluggedIn: true, isFullyCharged: false))
      let stop = try #require(
        controller.evaluateBattery(
          BatteryStatus(level: 0.8, isCharging: false, isPluggedIn: false, isFullyCharged: false)))
      #expect(!controller.isActive)
      await controller.start()
      await stop.value
      #expect(controller.isActive)
      #expect(!controller.noticeIsError)
    }
  }

  @Test(arguments: [false, true])
  func unplugRestoresPendingLidEnableAndPreservesRecoveryErrors(failsRestore: Bool) async throws {
    try await withController(stopOnUnplug: true) { controller, helper in
      await controller.start()
      controller.evaluateBattery(
        BatteryStatus(level: 0.8, isCharging: false, isPluggedIn: true, isFullyCharged: false))
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.restorationError = failsRestore ? "fixture-restore-failure" : nil
      let stop = try #require(
        controller.evaluateBattery(
          BatteryStatus(level: 0.8, isCharging: false, isPluggedIn: false, isFullyCharged: false)))
      #expect(!controller.isActive)
      helper.enableContinuation?.resume(returning: nil)
      helper.enableContinuation = nil
      await enable.value
      await stop.value
      #expect(helper.requests == [true, false])
      #expect(helper.sleepDisabled == failsRestore)
      #expect(controller.requiresTerminationRestoration == failsRestore)
      #expect(controller.noticeIsError == failsRestore)
      if failsRestore { #expect(controller.notice == "fixture-restore-failure") }
      helper.restorationError = nil
    }
  }

  @Test func unplugPreferenceDefaultsOffPersistsAndRoundTripsBackups() throws {
    let suite = "KeepAwakePreferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.keepAwakeStopOnUnplug)
    settings.keepAwakeStopOnUnplug = true
    #expect(AppSettings(defaults: defaults).keepAwakeStopOnUnplug)
    let data = try JSONEncoder().encode(settings.exportDocument())
    var document = try JSONDecoder().decode(SettingsDocument.self, from: data)
    // 导入测试只验证本选项，不改动进程的全局语言。
    document.language = nil
    settings.keepAwakeStopOnUnplug = false
    settings.apply(document)
    #expect(settings.keepAwakeStopOnUnplug)
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(settings.keepAwakeStopOnUnplug)
    var disabled = SettingsDocument()
    disabled.keepAwakeStopOnUnplug = false
    settings.apply(disabled)
    #expect(!settings.keepAwakeStopOnUnplug)
  }

  @Test func hiddenDisabledMonitoringRetainsOnlyNeededBatterySafetyDemand() async throws {
    let suite = "KeepAwakeUnplugDemand.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = []
    settings.menuBarItems = []
    settings.combinedOverviewItems = []
    settings.historyEnabled = false
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    await model.hub.setPaused(true)
    for _ in 0..<12 {
      await model.keepAwake.start()
      #expect(!model.demand.batterySafety)
      settings.keepAwakeStopOnUnplug = true
      let demand = model.demand
      #expect(demand.batterySafety && demand.battery)
      #expect(demand.interval == .seconds(10))
      #expect(!demand.power && !demand.appEnergy && demand.temperatures.isEmpty)
      await model.hub.update(demand)
      let paused = await model.hub.samplingDemand
      #expect(paused.battery && paused.interval == .seconds(30))
      #expect(!paused.cpu && !paused.memory && !paused.fans && !paused.processes)
      settings.keepAwakeStopOnUnplug = false
      await model.hub.update(model.demand)
      #expect(model.keepAwake.isActive && !model.demand.hasSamples)
      #expect(await !model.hub.samplingDemand.hasSamples)
      settings.keepAwakeStopOnUnplug = true
      await model.hub.update(model.demand)
      var snapshot = MetricsSnapshot()
      snapshot.isSafetySample = true
      snapshot.battery = BatteryStatus(
        level: 0.8, isCharging: false, isPluggedIn: true, isFullyCharged: false)
      model.handle(snapshot)
      snapshot.battery?.isPluggedIn = false
      model.handle(snapshot)
      #expect(!model.keepAwake.isActive)
      #expect(!model.demand.batterySafety && !model.demand.hasSamples)
      await model.hub.update(model.demand)
      #expect(await !model.hub.samplingDemand.hasSamples)
      settings.keepAwakeStopOnUnplug = false
      await model.keepAwake.stop(reason: nil)
    }
    await model.hub.stop()
  }

  @Test func safetyOnlySnapshotDoesNotPublishRegularMonitoringState() throws {
    let suite = "KeepAwakeSafetySnapshot.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      magpieClient: UnavailableMagpieClient())
    let initialBattery = model.store.battery
    var snapshot = MetricsSnapshot()
    snapshot.isSafetySample = true
    snapshot.battery = BatteryStatus(
      level: 0.1, isCharging: false, isPluggedIn: false, isFullyCharged: false)
    model.handle(snapshot)
    #expect(model.store.battery == initialBattery)
  }
  @Test func lowBatteryRestoresSleepWhileLidModeIsActive() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil { await Task.yield() }
      helper.enableContinuation?.resume(returning: nil)
      helper.enableContinuation = nil
      await enable.value
      controller.evaluateBattery(
        BatteryStatus(level: 0.01, isCharging: false, isPluggedIn: false, isFullyCharged: false))
      let deadline = ContinuousClock.now + .seconds(2)
      while helper.sleepDisabled, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(helper.requests == [true, false])
      #expect(!helper.sleepDisabled && !controller.lidClosedActive)
    }
  }
  @Test func stopWaitsForLateEnableAndRestoresSystemSleep() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      let stop = Task { await controller.stop(reason: nil) }
      while controller.isActive {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.enableContinuation?.resume(returning: nil)
      helper.enableContinuation = nil
      await enable.value
      await stop.value
      #expect(helper.requests == [true, false])
      #expect(!helper.sleepDisabled)
      #expect(!controller.isActive && !controller.lidClosedActive)
      #expect(!controller.requiresTerminationRestoration)
    }
  }

  @Test func canceledCallerStillCompensatesFailedLateEnable() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      enable.cancel()
      let stop = Task { await controller.stop(reason: nil) }
      while controller.isActive {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.enableContinuation?.resume(returning: "fixture-enable-failure")
      helper.enableContinuation = nil
      await enable.value
      await stop.value
      #expect(helper.requests == [true, false])
      #expect(!helper.sleepDisabled && !controller.requiresTerminationRestoration)
    }
  }

  @Test func failedRestoreRetainsRecoveryRequirementAndCanRetry() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.enableContinuation?.resume(returning: nil)
      helper.enableContinuation = nil
      await enable.value
      helper.restorationError = "fixture-restore-failure"
      await controller.stop(reason: nil)
      #expect(controller.requiresTerminationRestoration)
      #expect(controller.noticeIsError)
      #expect(helper.sleepDisabled)
      helper.restorationError = nil
      await controller.stop(reason: nil)
      #expect(!helper.sleepDisabled && !controller.requiresTerminationRestoration)
    }
  }

  @Test func failedEnableRestoresPotentialPartialSystemChange() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.enableContinuation?.resume(returning: "fixture-enable-failure")
      helper.enableContinuation = nil
      await enable.value
      #expect(helper.requests == [true, false])
      #expect(controller.noticeIsError)
      #expect(!controller.lidClosedRequested && !helper.sleepDisabled)
      #expect(!controller.requiresTerminationRestoration)
    }
  }

  @Test func terminationFreezesIntentWithoutWaitingForTheHelper() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      controller.releaseForTermination()
      #expect(!controller.isActive)
      #expect(controller.requiresTerminationRestoration)
      #expect(helper.enableContinuation != nil)
      helper.enableContinuation?.resume(returning: nil)
      helper.enableContinuation = nil
      await enable.value
      #expect(helper.requests == [true, false])
      #expect(!helper.sleepDisabled && !controller.requiresTerminationRestoration)
    }
  }

  @Test func resumeDuringPendingEnableKeepsLatestRequestWithoutOverlappingWrites() async throws {
    try await withController { controller, helper in
      await controller.start()
      let enable = Task { await controller.setLidClosed(true) }
      while helper.enableContinuation == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      let stop = Task { await controller.stop(reason: nil) }
      while controller.isActive {
        try Task.checkCancellation()
        await Task.yield()
      }
      let resume = Task { await controller.start() }
      while !controller.isActive {
        try Task.checkCancellation()
        await Task.yield()
      }
      helper.enableContinuation?.resume(returning: nil)
      helper.enableContinuation = nil
      await enable.value
      await stop.value
      await resume.value
      #expect(helper.requests == [true])
      #expect(controller.isActive && controller.lidClosedActive && helper.sleepDisabled)
    }
  }

  private func withController(
    stopOnUnplug: Bool = false,
    _ operation: (KeepAwakeController, SleepControlFixture) async throws -> Void
  ) async throws {
    let suite = "KeepAwakeLifecycleTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(stopOnUnplug, forKey: "keepAwakeStopOnUnplug")
    let helper = SleepControlFixture()
    let controller = KeepAwakeController(helper: helper, settings: AppSettings(defaults: defaults))
    do {
      try await operation(controller, helper)
    } catch {
      helper.enableContinuation?.resume(returning: "fixture-cancelled")
      helper.enableContinuation = nil
      await controller.stop(reason: nil)
      throw error
    }
    await controller.stop(reason: nil)
  }
}
