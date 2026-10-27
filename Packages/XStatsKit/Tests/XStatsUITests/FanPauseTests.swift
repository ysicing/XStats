// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SMC
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor private final class PausedFanClient: FanControlClient {
  var events: [String] = []
  var manualFans: Set<Int> = []
  var writeError: String?
  var resetError: String?
  var holdWrite = false
  var holdReset = false
  var writeContinuation: CheckedContinuation<String?, Never>?
  var resetContinuation: CheckedContinuation<String?, Never>?
  var resetWasCancelled = false

  func setFanTarget(fan: Int, rpm: Double) async -> String? {
    events.append("write:\(fan)")
    manualFans.insert(fan)
    if holdWrite {
      holdWrite = false
      return await withCheckedContinuation { writeContinuation = $0 }
    }
    return writeError
  }

  func resetAllFans() async -> String? {
    events.append("reset")
    let error: String?
    if holdReset {
      error = await withCheckedContinuation { resetContinuation = $0 }
    } else {
      error = resetError
    }
    resetWasCancelled = Task.isCancelled
    if error == nil { manualFans.removeAll() }
    return error
  }

  func finishWrite() {
    writeContinuation?.resume(returning: writeError)
    writeContinuation = nil
  }

  func finishReset() {
    holdReset = false
    resetContinuation?.resume(returning: resetError)
    resetContinuation = nil
  }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FanPauseTests {
  @Test(arguments: [false, true])
  func pausedMonitoringKeepsOnlyNecessarySafetySampling(resetFails: Bool) async throws {
    let suite = "FanPauseMonitoring.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let settings = AppSettings(defaults: defaults)
    settings.historyEnabled = true
    settings.menuBarItems = []
    let helper = PausedFanClient()
    let model = AppModel(
      settings: settings, historyURL: root.appendingPathComponent("history.sqlite"),
      magpieClient: nil,
      networkCacheDefaults: defaults, fanControl: helper)
    var snapshot = MetricsSnapshot()
    snapshot.sensors = SensorReadings(
      temperatures: [],
      fans: [
        FanState(
          id: 0, current: 2_000, minimum: 1_000, maximum: 5_000,
          target: 2_000, isManual: false)
      ], fanCount: 1)
    model.store.apply(snapshot)
    model.fans.customLevel = 0.1
    await model.fans.select(.custom)
    var retainedSnapshot = snapshot
    retainedSnapshot.sensors = SensorReadings(
      temperatures: [
        TemperatureSummary(group: .cpu, average: 110, maximum: 110, sensorCount: 1)
      ], fans: snapshot.sensors?.fans ?? [])
    model.store.apply(retainedSnapshot)
    helper.resetError = resetFails ? "fixture-reset-failure" : nil
    model.fans.setPaused(true)
    try await waitForPauseReset(model.fans, helper, events: 2)
    #expect(model.fans.requiresSafetySampling == resetFails)
    await model.hub.update(model.demand)
    await model.hub.setPaused(true)
    let demand = await model.hub.samplingDemand
    #expect(!demand.cpu && !demand.memory && !demand.network && !demand.processes)
    #expect(!demand.power && !demand.appEnergy && !demand.fans && !demand.battery)
    #expect(demand.temperatures == (resetFails ? [.cpu] : []))
    #expect(demand.hasSamples == resetFails)
    #expect(demand.interval == (resetFails ? model.demand.interval : .seconds(30)))
    if resetFails {
      helper.resetError = nil
      snapshot.isSafetySample = true
      snapshot.cpu = CPULoad(total: 0.9, user: 0.9, system: 0, perCore: [], loadAverage: [])
      snapshot.sensors = SensorReadings(
        temperatures: [
          TemperatureSummary(group: .cpu, average: 110, maximum: 110, sensorCount: 1)
        ], fans: [])
      model.handle(snapshot)
      try await waitUntil { model.fans.mode == .automatic && !model.fans.isApplying }
      await model.hub.update(model.demand)
      #expect(await model.hub.samplingDemand.hasSamples == false)
      #expect(model.store.cpu == nil && helper.manualFans.isEmpty)
      await model.history.flushAndWait()
      let database = try #require(model.history.database)
      #expect(await database.count() == 0)
    } else {
      let events = helper.events
      var batterySnapshot = MetricsSnapshot()
      batterySnapshot.isSafetySample = true
      batterySnapshot.battery = BatteryStatus(
        level: 0.5, isCharging: false, isPluggedIn: false, isFullyCharged: false)
      model.handle(batterySnapshot)
      try await Task.sleep(for: .milliseconds(20))
      #expect(model.fans.mode == .custom)
      #expect(helper.events == events)
    }
    await model.hub.setPaused(false)
    #expect(await model.hub.samplingDemand.cpu)
    await model.hub.stop()
  }

  @Test func pauseRestoresAutomaticAndResumeReappliesTheSelectedMode() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      fans.setPaused(true)
      try await waitForPauseReset(fans, client, events: 3)
      #expect(client.manualFans.isEmpty)
      #expect(fans.mode == .custom && !fans.requiresSafetySampling)
      // 暂停期间切档和手动提交都不能写入硬件
      await fans.select(.maximum)
      await fans.commitCustomLevel()
      await fans.reapply()
      #expect(client.events == ["write:0", "write:1", "reset"])
      fans.setPaused(false)
      await fans.reapply()
      #expect(client.manualFans == [0, 1])
      #expect(client.events == ["write:0", "write:1", "reset", "write:0", "write:1"])
    }
  }

  @Test(arguments: [false, true])
  func pauseWaitsForEveryInFlightWriteEvenWhenTheSelectionIsCancelled(cancel: Bool) async throws {
    try await withController { fans, client in
      client.holdWrite = true
      let selection = Task { await fans.select(.custom) }
      try await waitUntil { client.writeContinuation != nil }
      fans.setPaused(true)
      await Task.yield()
      #expect(client.events == ["write:0"])
      if cancel { selection.cancel() }
      client.finishWrite()
      await selection.value
      try await waitForPauseReset(fans, client, events: 3)
      #expect(client.events == ["write:0", "write:1", "reset"])
      // 复位任务独立于发起暂停的调用者，取消选择不能中断硬件复位
      #expect(client.manualFans.isEmpty && !client.resetWasCancelled)
      #expect(!fans.requiresSafetySampling)
    }
  }

  @Test func failedPauseKeepsSafetyActiveAndCanRetry() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      client.resetError = "fixture-reset-failure"
      fans.setPaused(true)
      try await waitForPauseReset(fans, client, events: 3)
      #expect(client.manualFans == [0, 1])
      #expect(fans.mode == .custom && fans.noticeIsError)
      #expect(fans.requiresSafetySampling)
      client.resetError = nil
      fans.evaluateSafety(temperature: 110)
      try await waitUntil { fans.mode == .automatic && !fans.isApplying }
      #expect(client.manualFans.isEmpty && !fans.noticeIsError)
      #expect(!fans.requiresSafetySampling)
    }
  }

  @Test func failedPauseRetriesWithoutLosingManualIntent() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      client.resetError = "fixture-reset-failure"
      fans.setPaused(true)
      try await waitForPauseReset(fans, client, events: 3)
      client.resetError = nil
      // 已暂停时再次请求暂停，会在上次失败后重新复位
      fans.setPaused(true)
      try await waitForPauseReset(fans, client, events: 4)
      #expect(fans.mode == .custom && !fans.noticeIsError)
      #expect(!fans.requiresSafetySampling)
      #expect(client.events == ["write:0", "write:1", "reset", "reset"])
    }
  }

  @Test func pauseRetainsFailedInFlightWriteAndFallbackRecovery() async throws {
    try await withController { fans, client in
      client.holdWrite = true
      client.writeError = "fixture-write-failure"
      client.resetError = "fixture-reset-failure"
      let selection = Task { await fans.select(.custom) }
      try await waitUntil { client.writeContinuation != nil }
      fans.setPaused(true)
      client.finishWrite()
      await selection.value
      // 写入失败后的兜底复位也失败，暂停复位随后执行
      try await waitForPauseReset(fans, client, events: 3)
      #expect(fans.mode == .custom && fans.noticeIsError)
      #expect(client.manualFans == [0])
      #expect(client.events == ["write:0", "reset", "reset"])
      client.resetError = nil
      fans.setPaused(true)
      try await waitForPauseReset(fans, client, events: 4)
      #expect(client.manualFans.isEmpty)
      #expect(!fans.requiresSafetySampling)
    }
  }

  @Test func resumeWaitsForPendingReset() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      client.holdReset = true
      fans.setPaused(true)
      try await waitUntil { client.resetContinuation != nil }
      fans.setPaused(false)
      let resumed = Task { await fans.reapply() }
      await Task.yield()
      #expect(client.events == ["write:0", "write:1", "reset"])
      client.finishReset()
      await resumed.value
      #expect(client.events == ["write:0", "write:1", "reset", "write:0", "write:1"])
      #expect(client.manualFans == [0, 1])
    }
  }

  @Test func pauseRequestedDuringResumeWinsOverOldReapply() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      client.holdReset = true
      fans.setPaused(true)
      try await waitUntil { client.resetContinuation != nil }
      fans.setPaused(false)
      let resumed = Task { await fans.reapply() }
      fans.setPaused(true)
      client.finishReset()
      await resumed.value
      #expect(client.manualFans.isEmpty)
      #expect(client.events == ["write:0", "write:1", "reset"])
      #expect(!fans.requiresSafetySampling)
    }
  }

  @Test func automaticModeDoesNotRequireAnInstalledHelperToPause() async throws {
    try await withController { fans, client in
      client.resetError = "fixture-helper-unavailable"
      fans.setPaused(true)
      try await Task.sleep(for: .milliseconds(20))
      #expect(client.events.isEmpty)
      #expect(!fans.requiresSafetySampling)
    }
  }

  @Test func immediateResumeStillCollectsThePauseReset() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      fans.setPaused(true)
      fans.setPaused(false)
      // 暂停复位已排队，恢复不能跳过硬件结果；随后按当前档位重新下发
      await fans.reapply()
      #expect(client.events == ["write:0", "write:1", "reset", "write:0", "write:1"])
      #expect(client.manualFans == [0, 1])
    }
  }

  private func waitForPauseReset(_ fans: FanController, _ client: PausedFanClient, events: Int)
    async throws
  {
    try await waitUntil { client.events.count == events && !fans.isApplying }
  }

  private func withController(
    _ body: (FanController, PausedFanClient) async throws -> Void
  ) async throws {
    let suite = "FanPauseTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let store = MetricsStore(readBattery: false)
    var snapshot = MetricsSnapshot()
    snapshot.sensors = SensorReadings(
      temperatures: [],
      fans: (0..<2).map { identifier in
        FanState(
          id: identifier, current: 2_000, minimum: 1_000, maximum: 5_000,
          target: 2_000, isManual: false)
      }, fanCount: 2)
    store.apply(snapshot)
    let client = PausedFanClient()
    let fans = FanController(helper: client, store: store, settings: settings)
    fans.customLevel = 0.1
    try await body(fans, client)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
}
