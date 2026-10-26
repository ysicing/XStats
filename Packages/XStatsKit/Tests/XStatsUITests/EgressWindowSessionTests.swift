// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct EgressWindowSessionTests {
  @Test func switchingTabsPreservesCompletedResultsAndClosingClearsThem() throws {
    let name = "EgressWindowSession.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(egress: egress)
    session.select(.webRTC)
    session.open()
    defer { session.close() }
    let webRTC = session.webRTC
    webRTC.phase = .complete
    webRTC.httpExit = "192.0.2.1"
    session.hideIP = true
    session.select(.dns)
    session.dns.phase = .complete
    session.select(.webRTC)
    #expect(session.webRTC === webRTC)
    #expect(session.webRTC.httpExit == "192.0.2.1")
    #expect(session.dns.phase == .complete)
    #expect(session.hideIP)
    // 最小化保留已完成结果，还原不会自动启动泄漏检测。
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
    #expect(!session.hideIP)
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
    let session = EgressWindowSession(egress: egress)
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
    let callsAfterSwitch = calls
    session.select(.dns)
    session.setSuspended(true)
    session.setSuspended(false)
    try await Task.sleep(for: .milliseconds(30))
    #expect(calls == callsAfterSwitch)
    #expect(session.webRTC.phase == .idle)
    #expect(session.dns.phase == .idle)
  }

  @Test func switchingAndMinimizingCancelUnfinishedLeakState() throws {
    let name = "EgressLeakSwitch.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let egress = EgressController(
      defaults: defaults, environmentReader: { ProxyEnvironment() },
      measure: { _, _ in [] }, geoLookup: { _, _, _ in nil })
    let session = EgressWindowSession(egress: egress)
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
}
