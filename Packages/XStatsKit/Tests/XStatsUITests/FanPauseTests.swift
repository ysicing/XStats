// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Metrics
import SMC
import Testing
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
  @Test func pauseRestoresAutomaticAndResumeReappliesTheSelectedMode() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      fans.setPaused(true)
      #expect(await fans.prepareForPause())
      #expect(client.manualFans.isEmpty)
      #expect(fans.mode == .custom)
      await fans.select(.maximum)
      await fans.commitCustomLevel()
      await fans.reapply()
      #expect(client.events == ["write:0", "write:1", "reset"])
      #expect(await fans.prepareForPause())
      #expect(client.events.count == 3)
      fans.setPaused(false)
      await fans.reapply()
      #expect(client.manualFans == [0, 1])
      #expect(client.events == ["write:0", "write:1", "reset", "write:0", "write:1"])
    }
  }

  @Test(arguments: [false, true])
  func pauseWaitsForEveryInFlightWriteEvenWhenTheCallerIsCancelled(cancel: Bool) async throws {
    try await withController { fans, client in
      client.holdWrite = true
      let selection = Task { await fans.select(.custom) }
      try await waitUntil { client.writeContinuation != nil }
      fans.setPaused(true)
      let preparation = Task { await fans.prepareForPause() }
      await Task.yield()
      #expect(client.events == ["write:0"])
      if cancel {
        selection.cancel()
        preparation.cancel()
      }
      client.finishWrite()
      await selection.value
      let prepared = await preparation.value
      #expect(prepared == !cancel)
      #expect(client.events == ["write:0", "write:1", "reset"])
      #expect(client.manualFans.isEmpty && !client.resetWasCancelled)
      #expect(await fans.prepareForPause())
    }
  }

  @Test func failedPauseKeepsSafetyActiveAndCanRetry() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      client.resetError = "fixture-reset-failure"
      #expect(await fans.prepareForPause() == false)
      #expect(client.manualFans == [0, 1])
      #expect(fans.mode == .custom && fans.noticeIsError)
      client.resetError = nil
      fans.evaluateSafety(temperature: 110)
      try await waitUntil { fans.mode == .automatic && !fans.isApplying }
      #expect(client.manualFans.isEmpty && !fans.noticeIsError)
      #expect(await fans.prepareForPause())
    }
  }

  @Test func failedPauseRetriesWithoutLosingManualIntent() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      client.resetError = "fixture-reset-failure"
      #expect(await fans.prepareForPause() == false)
      client.resetError = nil
      #expect(await fans.prepareForPause())
      #expect(fans.mode == .custom && !fans.noticeIsError)
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
      let preparation = Task { await fans.prepareForPause() }
      client.finishWrite()
      await selection.value
      #expect(await preparation.value == false)
      #expect(fans.mode == .custom && fans.noticeIsError)
      #expect(client.manualFans == [0])
      #expect(client.events == ["write:0", "reset", "reset"])
      client.resetError = nil
      #expect(await fans.prepareForPause())
      #expect(client.manualFans.isEmpty)
    }
  }

  @Test func resumeWaitsForPendingResetAndInvalidatesOldPauseResult() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      client.holdReset = true
      let preparation = Task { await fans.prepareForPause() }
      try await waitUntil { client.resetContinuation != nil }
      fans.setPaused(false)
      let resumed = Task { await fans.reapply() }
      await Task.yield()
      #expect(client.events == ["write:0", "write:1", "reset"])
      client.finishReset()
      #expect(await preparation.value == false)
      await resumed.value
      #expect(client.events == ["write:0", "write:1", "reset", "write:0", "write:1"])
      #expect(client.manualFans == [0, 1])
      #expect(await fans.prepareForPause())
      #expect(client.events == ["write:0", "write:1", "reset", "write:0", "write:1", "reset"])
      #expect(client.manualFans.isEmpty)
    }
  }

  @Test func newPauseDuringResumeCannotBeOverwrittenByAnOldReapply() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      client.holdReset = true
      let first = Task { await fans.prepareForPause() }
      try await waitUntil { client.resetContinuation != nil }
      fans.setPaused(false)
      let resumed = Task { await fans.reapply() }
      fans.setPaused(true)
      let second = Task { await fans.prepareForPause() }
      client.finishReset()
      #expect(await first.value == false)
      #expect(await second.value)
      await resumed.value
      #expect(client.manualFans.isEmpty)
      #expect(client.events == ["write:0", "write:1", "reset"])
    }
  }

  @Test func cancelledPauseWaiterStillFinishesTheHardwareReset() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      client.holdReset = true
      let preparation = Task { await fans.prepareForPause() }
      try await waitUntil { client.resetContinuation != nil }
      preparation.cancel()
      client.finishReset()
      #expect(await preparation.value == false)
      #expect(client.manualFans.isEmpty && !client.resetWasCancelled)
      #expect(await fans.prepareForPause())
    }
  }

  @Test func automaticModeDoesNotRequireAnInstalledHelperToPause() async throws {
    try await withController { fans, client in
      client.resetError = "fixture-helper-unavailable"
      #expect(await fans.prepareForPause())
      #expect(client.events.isEmpty)
    }
  }

  @Test func cancelledPreparationCannotStartANewPauseAfterResume() async throws {
    try await withController { fans, client in
      await fans.select(.custom)
      let preparation = Task { await fans.prepareForPause() }
      preparation.cancel()
      fans.setPaused(false)
      #expect(await preparation.value == false)
      await fans.reapply()
      #expect(client.events == ["write:0", "write:1", "write:0", "write:1"])
      #expect(client.manualFans == [0, 1])
    }
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
