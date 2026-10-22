// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Metrics
import Testing
@testable import XStatsUI

private actor EgressLifecycleProbe {
  private var gate: CheckedContinuation<Void, Never>?
  private var geoGate: CheckedContinuation<Void, Never>?
  private let holdGeo: Bool
  private(set) var measuring = false
  private(set) var completed = false
  private(set) var wasCancelled = false
  private(set) var geoCalls = 0
  private(set) var geoCompleted = false
  private(set) var geoWasCancelled = false

  init(holdGeo: Bool = false) { self.holdGeo = holdGeo }

  func measure(progress: @escaping @Sendable (Int) -> Void) async -> [EgressHit] {
    measuring = true
    await withCheckedContinuation { gate = $0 }
    wasCancelled = Task.isCancelled
    progress(99)
    completed = true
    return [EgressHit(targetID: EgressTarget.cloudflare.id, route: .interface, ip: "192.0.2.10")]
  }

  func release() {
    gate?.resume()
    gate = nil
  }

  func geo() async -> (ip: String, geo: EgressGeo)? {
    geoCalls += 1
    if holdGeo { await withCheckedContinuation { geoGate = $0 } }
    geoWasCancelled = Task.isCancelled
    geoCompleted = true
    return nil
  }

  func releaseGeo() {
    geoGate?.resume()
    geoGate = nil
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EgressLifecycleTests {
  @Test func closingDuringGeoLookupRejectsLateReportAndPersistence() async throws {
    let suite = "EgressGeoLifecycle.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let probe = EgressLifecycleProbe(holdGeo: true)
    let controller = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, progress in await probe.measure(progress: progress) },
      geoLookup: { _, _, _ in await probe.geo() })
    controller.check()
    try await waitUntil { await probe.measuring }
    await probe.release()
    try await waitUntil { await probe.geoCalls == 1 }
    let task = try #require(controller.checkTask)
    controller.windowDidClose()
    #expect(!controller.isChecking)
    await probe.releaseGeo()
    await task.value
    #expect(await probe.geoCompleted)
    #expect(await probe.geoWasCancelled)
    #expect(controller.report == nil)
    #expect(defaults.data(forKey: "egressReport2") == nil)
  }

  @Test func pausingCancelsWorkAndRejectsNewChecksUntilResumed() async throws {
    let suite = "EgressPauseLifecycle.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let probe = EgressLifecycleProbe()
    let controller = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, progress in await probe.measure(progress: progress) },
      geoLookup: { _, _, _ in await probe.geo() })
    controller.check()
    try await waitUntil { await probe.measuring }
    let task = try #require(controller.checkTask)
    controller.setPaused(true)
    controller.check()
    #expect(!controller.isChecking)
    await probe.release()
    await task.value
    #expect(await probe.completed)
    #expect(await probe.wasCancelled)
    #expect(await probe.geoCalls == 0)
    #expect(controller.report == nil)
    controller.setPaused(false)
    controller.check()
    #expect(controller.isChecking)
    let resumed = try #require(controller.checkTask)
    controller.windowDidClose()
    await resumed.value
    #expect(!controller.isChecking)
  }
  @Test func closingCancelsMeasurementAndRejectsLateProgressGeoAndPersistence() async throws {
    let suite = "EgressLifecycle.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let probe = EgressLifecycleProbe()
    let controller = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, progress in await probe.measure(progress: progress) },
      geoLookup: { _, _, _ in await probe.geo() })
    controller.check()
    try await waitUntil { await probe.measuring }
    let task = try #require(controller.checkTask)
    controller.windowDidClose()
    #expect(!controller.isChecking)
    await probe.release()
    await task.value
    #expect(await probe.completed)
    #expect(await probe.wasCancelled)
    #expect(await probe.geoCalls == 0)
    #expect(controller.report == nil)
    #expect(controller.progress == 0)
    #expect(defaults.data(forKey: "egressReport2") == nil)
  }

  private func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await condition()), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await condition())
  }
}
