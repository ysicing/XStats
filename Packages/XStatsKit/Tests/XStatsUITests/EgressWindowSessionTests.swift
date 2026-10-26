// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct EgressWindowSessionTests {
  @Test func sharedCheckTargetsCurrentTabAndIgnoresDuplicateRequests() async throws {
    let name = "EgressSharedCheck.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var overviewCalls = 0
    var webRTCCalls = 0
    var dnsCalls = 0
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in
        await MainActor.run { overviewCalls += 1 }
        return []
      }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(
      egress: egress,
      makeController: {
        NetworkLeakTestController(
          webRTCProbe: {
            webRTCCalls += 1
            if webRTCCalls > 1 { try await Task.sleep(for: .seconds(30)) }
            return WebRTCLeakProbe.Result(services: [])
          }, exitLookup: { "192.0.2.1" },
          dnsProbe: {
            dnsCalls += 1
            if dnsCalls > 1 { try await Task.sleep(for: .seconds(30)) }
            return try Self.dnsResult()
          })
      })
    session.check()
    #expect(!session.isChecking)
    session.open()
    defer { session.close() }
    try await waitUntil { egress.report != nil && !session.isChecking }
    session.select(.domestic)
    session.check()
    #expect(session.isChecking)
    try await waitUntil { overviewCalls == 2 && !session.isChecking }

    for tab in [EgressWindowSession.Tab.webRTC, .dns] {
      session.select(tab)
      let controller = tab == .webRTC ? session.webRTC : session.dns
      try await waitUntil { controller.phase == .complete }
      #expect(!session.isChecking)
      session.check()
      #expect(session.isChecking)
      session.check()
      try await waitUntil { tab == .webRTC ? webRTCCalls == 2 : dnsCalls == 2 }
      let task = try #require(controller.task)
      session.cancelLeakTests()
      #expect(!session.isChecking)
      await task.value
      #expect(controller.phase == .cancelled)
      #expect(controller.httpExit == nil)
      #expect(controller.dnsResult == nil)
    }
    #expect(overviewCalls == 2)
    #expect(webRTCCalls == 2)
    #expect(dnsCalls == 2)
    session.close()
    session.check()
    #expect(!session.isChecking)
    #expect(overviewCalls == 2)
  }

  @Test func sharedCheckDoesNotRunWhileHiddenOrSuspended() async throws {
    let name = "EgressSharedCheckInactive.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(egress: egress, makeController: Self.offlineController)
    session.open()
    defer { session.close() }
    try await waitUntil { egress.report != nil && !egress.isChecking }
    session.setHidden(true)
    for tab in [EgressWindowSession.Tab.overview, .webRTC, .dns] {
      session.select(tab)
      session.check()
      #expect(!session.isChecking)
    }
    session.setSuspended(true)
    session.setHidden(false)
    for tab in [EgressWindowSession.Tab.overview, .webRTC, .dns] {
      session.select(tab)
      session.check()
      #expect(!session.isChecking)
    }
    #expect(session.webRTC.phase == .idle)
    #expect(session.dns.phase == .idle)
  }

  @Test func openingLeakTabAutomaticallyStartsOnlyVisibleTest() async throws {
    let name = "EgressLeakAutomatic.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(egress: egress, makeController: Self.offlineController)
    session.select(.webRTC)
    #expect(session.webRTC.phase == .idle)
    session.open()
    defer { session.close() }
    let deadline = ContinuousClock.now + .seconds(1)
    while session.webRTC.phase == .idle, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.webRTC.phase != .idle)
    #expect(session.dns.phase == .idle)
    #expect(!egress.isChecking)
  }

  @Test func switchingTabsPreservesCompletedResultsAndClosingClearsThem() throws {
    let name = "EgressWindowSession.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(egress: egress, makeController: Self.offlineController)
    session.select(.webRTC)
    session.open()
    defer { session.close() }
    let webRTC = session.webRTC
    webRTC.phase = .complete
    webRTC.httpExit = "192.0.2.1"
    session.select(.dns)
    session.dns.phase = .complete
    session.select(.webRTC)
    #expect(session.webRTC === webRTC)
    #expect(session.webRTC.httpExit == "192.0.2.1")
    #expect(session.dns.phase == .complete)
    // 最小化保留已完成结果，还原复用未过期且网络未变的结果。
    session.setSuspended(true)
    session.setSuspended(false)
    #expect(session.webRTC.phase == .complete)
    #expect(!egress.isChecking)
    session.close()
    #expect(session.tab == .overview)
    #expect(session.webRTC !== webRTC)
    #expect(session.webRTC.phase == .idle)
    #expect(session.webRTC.httpExit == nil)
    #expect(session.dns.phase == .idle)
  }

  @Test func leavingOverviewCancelsMeasurementAndRejectsLateReport() async throws {
    let name = "EgressWindowSwitch.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var calls = 0
    let egress = EgressController(
      defaults: defaults,
      environmentReader: {
        calls += 1
        return ProxyEnvironment()
      },
      measure: { _, _ in
        do { try await Task.sleep(for: .seconds(30)) } catch {}
        return [EgressHit(targetID: EgressTarget.cloudflare.id, route: .interface, ip: "192.0.2.1")]
      },
      geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(egress: egress, makeController: Self.offlineController)
    session.open()
    defer { session.close() }
    let deadline = ContinuousClock.now + .seconds(3)
    while egress.checkTask == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let task = try #require(egress.checkTask)
    session.select(.webRTC)
    await task.value
    #expect(!egress.isChecking)
    #expect(egress.report == nil)
    #expect(defaults.data(forKey: "egressReport2") == nil)
    try await waitUntil { session.webRTC.phase == .complete }
    let callsAfterSwitch = calls
    session.select(.dns)
    session.setSuspended(true)
    session.setSuspended(false)
    try await waitUntil { session.dns.phase == .complete }
    #expect(calls > callsAfterSwitch)
    #expect(session.webRTC.phase == .complete)
    #expect(session.dns.phase == .complete)
  }

  @Test func switchingAndMinimizingCancelUnfinishedLeakState() throws {
    let name = "EgressLeakSwitch.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(egress: egress, makeController: Self.offlineController)
    session.select(.webRTC)
    session.open()
    defer { session.close() }
    session.webRTC.phase = .running
    session.select(.dns)
    #expect(session.webRTC.phase == .cancelled)
    session.dns.phase = .running
    session.setSuspended(true)
    #expect(session.dns.phase == .cancelled)
    session.setSuspended(false)
    #expect(session.dns.phase == .cancelled)
  }

  @Test func inactivityCancelsBothLeakTestsAndPreservesCompletedResults() throws {
    let name = "EgressLeakInactivity.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(egress: egress, makeController: Self.offlineController)
    session.select(.dns)
    session.open()
    defer { session.close() }
    session.webRTC.phase = .running
    session.dns.phase = .running
    session.cancelLeakTests()
    #expect(session.webRTC.phase == .cancelled)
    #expect(session.dns.phase == .cancelled)
    #expect(session.tab == .dns)
    session.cancelLeakTests()
    #expect(session.dns.phase == .cancelled)

    session.webRTC.phase = .complete
    session.webRTC.httpExit = "192.0.2.1"
    session.dns.phase = .running
    session.cancelLeakTests()
    #expect(session.webRTC.phase == .complete)
    #expect(session.webRTC.httpExit == "192.0.2.1")
    #expect(session.dns.phase == .cancelled)
    #expect(!egress.isChecking)
  }

  @Test func automaticChecksReuseFreshResultsAndRefreshForNetworkChangesAndStaleness() async throws
  {
    let name = "EgressLeakRefresh.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var environment = ProxyEnvironment(dnsServers: ["192.0.2.53"])
    var reads = 0
    var webRTCCalls = 0
    var dnsCalls = 0
    var date = Date(timeIntervalSince1970: 1_000)
    let egress = EgressController(
      defaults: defaults,
      environmentReader: {
        reads += 1
        return environment
      },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(
      egress: egress,
      makeController: {
        NetworkLeakTestController(
          webRTCProbe: {
            webRTCCalls += 1
            return WebRTCLeakProbe.Result(services: [])
          }, exitLookup: { "192.0.2.1" },
          dnsProbe: {
            dnsCalls += 1
            return try Self.dnsResult()
          })
      }, now: { date })
    session.select(.webRTC)
    session.open()
    defer { session.close() }
    try await waitUntil { session.webRTC.phase == .complete }
    #expect(webRTCCalls == 1)
    #expect(dnsCalls == 0)
    session.select(.dns)
    try await waitUntil { session.dns.phase == .complete }
    #expect(dnsCalls == 1)
    let previousReads = reads
    session.select(.webRTC)
    try await waitUntil { reads > previousReads }
    #expect(webRTCCalls == 1)

    // 网络变更使用同一个环境观察任务，不用额外的常驻定时器。
    environment.dnsServers = ["192.0.2.54"]
    try await waitUntil { webRTCCalls == 2 && session.webRTC.phase == .complete }
    #expect(dnsCalls == 1)
    session.select(.dns)
    try await waitUntil { dnsCalls == 2 && session.dns.phase == .complete }

    session.setSuspended(true)
    date.addTimeInterval(601)
    let suspendedReads = reads
    try await Task.sleep(for: .milliseconds(30))
    #expect(reads == suspendedReads)
    session.setHidden(true)
    session.setSuspended(false)
    #expect(reads == suspendedReads)
    #expect(dnsCalls == 2)
    session.setHidden(false)
    try await waitUntil { dnsCalls == 3 && session.dns.phase == .complete }
    #expect(webRTCCalls == 2)
    #expect(!egress.isChecking)
  }

  @Test func switchingSiteCategoriesDoesNotRestartOverviewMeasurement() async throws {
    let name = "EgressSiteFilter.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in
        try? await Task.sleep(for: .seconds(30))
        return []
      }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(egress: egress, makeController: Self.offlineController)
    session.open()
    defer { session.close() }
    try await waitUntil { egress.isChecking }
    let task = try #require(egress.checkTask)
    session.select(.domestic)
    session.select(.developer)
    #expect(egress.isChecking)
    session.close()
    await task.value
    #expect(!egress.isChecking)
  }

  @Test func switchingCancelsAutomaticProbeAndRejectsLateResults() async throws {
    let name = "EgressLeakLateResult.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var gate: CheckedContinuation<WebRTCLeakProbe.Result, Never>?
    var exitCalls = 0
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(
      egress: egress,
      makeController: {
        NetworkLeakTestController(
          webRTCProbe: { await withCheckedContinuation { gate = $0 } },
          exitLookup: {
            exitCalls += 1
            return "192.0.2.1"
          }, dnsProbe: { try Self.dnsResult() })
      })
    session.select(.webRTC)
    session.open()
    defer { session.close() }
    try await waitUntil { gate != nil }
    let oldTask = try #require(session.webRTC.task)
    session.select(.dns)
    #expect(session.webRTC.phase == .cancelled)
    gate?.resume(returning: WebRTCLeakProbe.Result(services: []))
    gate = nil
    await oldTask.value
    try await waitUntil { session.dns.phase == .complete }
    #expect(exitCalls == 0)
    #expect(session.webRTC.phase == .cancelled)
    #expect(session.webRTC.httpExit == nil)
    #expect(session.webRTC.webRTCServices.isEmpty)
    #expect(session.webRTC.task == nil)
  }

  private static func dnsResult() throws -> NetworkLeakTest.DNSResult {
    try NetworkLeakTest.decodeDNS(
      Data("[{\"ip\":\"192.0.2.53\",\"type\":\"dns\"}]".utf8))
  }

  private static func offlineController() -> NetworkLeakTestController {
    NetworkLeakTestController(
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
