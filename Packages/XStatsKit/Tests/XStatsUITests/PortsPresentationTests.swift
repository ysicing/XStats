// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct PortsPresentationTests {
  private func makeSettings() -> AppSettings {
    let name = "PortsPresentationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return AppSettings(defaults: defaults)
  }

  private func socket(
    pid: Int32, name: String = "proc", state: PortSocket.State = .listening, uid: UInt32 = getuid(),
    port: Int, remote: String? = nil, remotePort: Int? = nil
  ) -> PortSocket {
    PortSocket(
      pid: pid, name: name, uid: uid, socketID: UInt64(pid), transport: .tcp, state: state,
      localAddress: nil,
      localPort: port, remoteAddress: remote, remotePort: remotePort)
  }

  @Test func portsStayOffUntilEnabled() {
    let settings = makeSettings()
    #expect(!settings.portsEnabled)
    settings.panelTab = .ports
    #expect(settings.panelTab == .settingsFeatures)
    #expect(AppDeepLink.page(.ports, settings: settings) == .settingsFeatures)

    settings.portsEnabled = true
    settings.panelTab = .ports
    #expect(settings.panelTab == .ports)
    #expect(AppDeepLink.page(.ports, settings: settings) == .ports)
  }

  @Test func disablingPortsLeavesThePortsPage() {
    let settings = makeSettings()
    settings.portsEnabled = true
    settings.panelTab = .ports
    settings.portsEnabled = false
    #expect(settings.panelTab == .settingsFeatures)
  }

  @Test func listingFiltersSearchesAndSortsByPortThenPID() {
    let sockets = [
      socket(pid: 20, name: "node", port: 8080),
      socket(pid: 10, name: "postgres", port: 3000),
      socket(
        pid: 30, name: "Safari", state: .established, port: 3000, remote: "1.2.3.4", remotePort: 443
      ),
    ]
    func pids(
      filter: PortFilter = .all, query: String = "", ascending: Bool = true
    ) -> [Int32] {
      PortListing.rows(
        sockets, filter: filter, query: query, column: .port, ascending: ascending, rates: [:]
      ).map(\.pid)
    }

    // 端口相同时按 PID 稳定排序
    #expect(pids() == [10, 30, 20])
    #expect(pids(ascending: false) == [20, 10, 30])
    #expect(pids(filter: .listening) == [10, 20])
    #expect(pids(filter: .established) == [30])
    #expect(pids(query: "1.2.3") == [30])
    #expect(pids(query: "rails") == [10, 30])
    #expect(pids(query: "30") == [10, 30])
    #expect(pids(query: "safari") == [30])
  }

  @Test func quitIsBlockedForSystemOwnedAndSelfProcesses() throws {
    let own = socket(pid: 999_999, port: 9000)
    #expect(PortActions.quitBlockedReason(own) == nil)

    let root = socket(pid: 1, uid: 0, port: 80)
    #expect(PortActions.quitBlockedReason(root) != nil)

    let otherUser = socket(pid: 999_998, uid: getuid() &+ 1, port: 9001)
    #expect(PortActions.quitBlockedReason(otherUser) != nil)

    let selfProcess = socket(pid: getpid(), port: 9002)
    #expect(PortActions.quitBlockedReason(selfProcess) != nil)

    let protected = try #require(ProcessActions.protectedNames.first)
    let system = socket(pid: 999_997, name: protected, port: 9003)
    #expect(PortActions.quitBlockedReason(system) != nil)
  }
}
