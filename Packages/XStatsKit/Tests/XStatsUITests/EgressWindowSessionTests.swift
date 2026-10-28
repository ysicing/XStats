// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct EgressWindowSessionTests {
  @Test func sharedCheckStartsAllTestsAndSwitchingDoesNotCancelOrDuplicate() async throws {
    let name = "EgressSharedCheck.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let overviewGate = MeasurementGate()
    var webRTCGate: CheckedContinuation<Void, Never>?
    var dnsGate: CheckedContinuation<Void, Never>?
    var overviewCalls = 0
    var webRTCCalls = 0
    var dnsCalls = 0
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in
        await MainActor.run { overviewCalls += 1 }
        await overviewGate.wait()
        return []
      }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(
      egress: egress,
      makeController: {
        NetworkLeakTestController(
          geoLookup: { _ in nil },
          webRTCProbe: {
            webRTCCalls += 1
            await withCheckedContinuation { webRTCGate = $0 }
            return WebRTCLeakProbe.Result(services: [])
          }, exitLookup: { "192.0.2.1" },
          dnsProbe: {
            dnsCalls += 1
            await withCheckedContinuation { dnsGate = $0 }
            return try Self.dnsResult()
          })
      })
    session.check()
    #expect(!session.isChecking)
    session.open()
    defer { session.close() }
    // 三项都已进入测量，且没有任何一项完成：证明并发启动而非切页或顺序触发。
    try await waitUntil { overviewGate.continuation != nil && webRTCGate != nil && dnsGate != nil }
    for tab in EgressWindowSession.Tab.allCases {
      session.select(tab)
      session.check()
      #expect(session.isChecking)
      #expect(session.webRTC.phase == .running)
      #expect(session.dns.phase == .running)
      #expect(egress.isChecking)
    }
    #expect(overviewCalls == 1)
    #expect(webRTCCalls == 1)
    #expect(dnsCalls == 1)
    overviewGate.continuation?.resume()
    webRTCGate?.resume()
    dnsGate?.resume()
    try await waitUntil { !session.isChecking }
    #expect(egress.report != nil)
    #expect(session.webRTC.phase == .complete)
    #expect(session.dns.phase == .complete)
  }

  @Test func completedDatesBelongToSelectedResultAndClearOnFailedRecheck() async throws {
    let name = "EgressDates.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var failDNS = false
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(
      egress: egress,
      makeController: {
        NetworkLeakTestController(
          geoLookup: { _ in nil },
          webRTCProbe: { WebRTCLeakProbe.Result(services: []) },
          exitLookup: { "192.0.2.1" },
          dnsProbe: {
            if failDNS { throw NetworkLeakTest.Failure.unavailable }
            return try Self.dnsResult()
          })
      })
    session.open()
    defer { session.close() }
    try await waitUntil { egress.report != nil && !session.isChecking }
    #expect(session.lastCheckedAt == egress.report?.date)
    session.select(.webRTC)
    #expect(session.lastCheckedAt == session.webRTC.completedAt)
    #expect(session.lastCheckedAt != nil)
    session.select(.dns)
    #expect(session.lastCheckedAt == session.dns.completedAt)
    #expect(session.lastCheckedAt != nil)
    failDNS = true
    session.check()
    #expect(session.lastCheckedAt == nil)
    try await waitUntil { !session.isChecking }
    #expect(session.dns.phase == .failed)
    #expect(session.lastCheckedAt == nil)
    session.select(.webRTC)
    #expect(session.lastCheckedAt != nil)
    session.close()
    session.select(.dns)
    #expect(session.lastCheckedAt == nil)
  }

  @Test func hiddenSuspendedAndClosedSessionsDoNotStartChecks() async throws {
    let name = "EgressInactive.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(egress: egress, makeController: Self.offlineController)
    session.setHidden(true)
    session.open()
    defer { session.close() }
    session.check()
    #expect(!session.isChecking)
    #expect(session.webRTC.phase == .idle)
    #expect(session.dns.phase == .idle)
    session.setSuspended(true)
    session.setHidden(false)
    session.check()
    #expect(!session.isChecking)
    #expect(egress.report == nil)
    session.close()
    session.check()
    #expect(!session.isChecking)
  }

  @Test(arguments: [false, true])
  func cancellingBatchRejectsLateResults(manually: Bool) async throws {
    let name = "EgressCancellation.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var webRTCGate: CheckedContinuation<WebRTCLeakProbe.Result, Never>?
    var dnsGate: CheckedContinuation<NetworkLeakTest.DNSResult, Never>?
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in
        try? await Task.sleep(for: .seconds(30))
        return []
      }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(
      egress: egress,
      makeController: {
        NetworkLeakTestController(
          geoLookup: { _ in nil },
          webRTCProbe: { await withCheckedContinuation { webRTCGate = $0 } },
          exitLookup: { "192.0.2.1" },
          dnsProbe: { await withCheckedContinuation { dnsGate = $0 } })
      })
    session.open()
    defer { session.close() }
    try await waitUntil { webRTCGate != nil && dnsGate != nil && egress.isChecking }
    let oldWebRTC = session.webRTC
    let oldDNS = session.dns
    let webRTCTask = try #require(oldWebRTC.task)
    let dnsTask = try #require(oldDNS.task)
    let overviewTask = try #require(egress.checkTask)
    if manually {
      session.cancelChecks()
    } else {
      session.setSuspended(true)
    }
    #expect(!session.isChecking)
    #expect(oldWebRTC.phase == .cancelled)
    #expect(oldDNS.phase == .cancelled)
    webRTCGate?.resume(returning: WebRTCLeakProbe.Result(services: []))
    dnsGate?.resume(returning: try Self.dnsResult())
    await webRTCTask.value
    await dnsTask.value
    await overviewTask.value
    #expect(oldWebRTC.completedAt == nil)
    #expect(oldDNS.completedAt == nil)
    #expect(oldDNS.dnsResult == nil)
    #expect(egress.report == nil)
    #expect(defaults.data(forKey: "egressReport2") == nil)
    session.close()
    #expect(session.webRTC === oldWebRTC)
    #expect(session.dns === oldDNS)
    #expect(session.tab == .overview)
  }

  @Test func networkChangesRefreshAllAndFreshResultsSurviveSwitchingAndResume() async throws {
    let name = "EgressRefresh.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var environment = ProxyEnvironment(dnsServers: ["192.0.2.53"])
    var calls = 0
    var date = Date()
    let egress = EgressController(
      defaults: defaults, environmentReader: { environment },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(
      egress: egress,
      makeController: {
        NetworkLeakTestController(
          geoLookup: { _ in nil },
          webRTCProbe: {
            calls += 1
            return WebRTCLeakProbe.Result(services: [])
          }, exitLookup: { "192.0.2.1" }, dnsProbe: { try Self.dnsResult() })
      }, now: { date })
    session.open()
    defer { session.close() }
    try await waitUntil { calls == 1 && !session.isChecking }
    let initialDNSDate = session.dns.completedAt
    session.select(.dns)
    session.select(.webRTC)
    session.setSuspended(true)
    session.setSuspended(false)
    try await Task.sleep(for: .milliseconds(50))
    #expect(calls == 1)
    #expect(session.dns.completedAt == initialDNSDate)
    environment.dnsServers = ["192.0.2.54"]
    try await waitUntil { calls == 2 && !session.isChecking }
    #expect(egress.report?.environment.signature == environment.signature)
    #expect(session.dns.completedAt != initialDNSDate)
    session.setSuspended(true)
    date.addTimeInterval(601)
    session.setSuspended(false)
    try await waitUntil { calls == 3 && !session.isChecking }
  }

  @Test func reopeningWithinFreshWindowKeepsCompletedBatch() async throws {
    let name = "EgressReopen.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let environment = ProxyEnvironment(dnsServers: ["192.0.2.53"])
    var reads = 0
    var calls = 0
    var date = Date()
    let egress = EgressController(
      defaults: defaults,
      environmentReader: {
        reads += 1
        return environment
      }, measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(
      egress: egress,
      makeController: {
        NetworkLeakTestController(
          geoLookup: { _ in nil },
          webRTCProbe: {
            calls += 1
            return WebRTCLeakProbe.Result(services: [])
          }, exitLookup: { "192.0.2.1" }, dnsProbe: { try Self.dnsResult() })
      }, now: { date })
    session.open()
    try await waitUntil { calls == 1 && !session.isChecking }
    let report = egress.report
    let webRTC = session.webRTC
    session.close()
    // 十分钟内、同一网络重开：三项结果沿用，不启动任何检测。
    date.addTimeInterval(60)
    let readsBeforeReopen = reads
    session.open()
    defer { session.close() }
    try await waitUntil { reads > readsBeforeReopen }
    try await Task.sleep(for: .milliseconds(50))
    #expect(calls == 1)
    #expect(!session.isChecking)
    #expect(egress.report?.date == report?.date)
    #expect(session.webRTC === webRTC)
    #expect(session.webRTC.phase == .complete)
    #expect(session.dns.phase == .complete)
  }

  @Test func failedOrCancelledChecksDoNotRetryOnEveryEnvironmentTick() async throws {
    let name = "EgressNoRetry.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var reads = 0
    var calls = 0
    let egress = EgressController(
      defaults: defaults,
      environmentReader: {
        reads += 1
        return ProxyEnvironment()
      }, measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(
      egress: egress,
      makeController: {
        NetworkLeakTestController(
          geoLookup: { _ in nil },
          webRTCProbe: {
            calls += 1
            throw NetworkLeakTest.Failure.unavailable
          }, exitLookup: { nil }, dnsProbe: { throw NetworkLeakTest.Failure.unavailable })
      })
    session.open()
    defer { session.close() }
    try await waitUntil { calls == 1 && !session.isChecking }
    let initialReads = reads
    try await waitUntil { reads > initialReads }
    #expect(calls == 1)
    session.select(.dns)
    session.select(.webRTC)
    #expect(calls == 1)
  }

  private static func dnsResult() throws -> NetworkLeakTest.DNSResult {
    try NetworkLeakTest.decodeDNS(Data("[{\"ip\":\"192.0.2.53\",\"type\":\"dns\"}]".utf8))
  }

  @MainActor private final class MeasurementGate {
    var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
      await withCheckedContinuation { continuation = $0 }
    }
  }

  private static func offlineController() -> NetworkLeakTestController {
    NetworkLeakTestController(
      geoLookup: { _ in nil },
      webRTCProbe: { WebRTCLeakProbe.Result(services: []) },
      exitLookup: { "192.0.2.1" }, dnsProbe: { try dnsResult() })
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
}
