// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
final class PortsPresentationTests {
  private var suites: [String] = []

  deinit {
    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
  }

  private func makeSettings() -> AppSettings {
    let name = "PortsPresentationTests.\(UUID().uuidString)"
    suites.append(name)
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

  @Test func placementDefaultsToSidebarAndOnlyShowsEnabledEntrances() {
    let settings = makeSettings()
    #expect(settings.portsPlacement == .sidebar)
    for placement in PortsPlacement.allCases {
      settings.portsPlacement = placement
      settings.portsEnabled = false
      #expect(!settings.showsPortsInSidebar)
      #expect(!settings.showsPortsInNetwork)
      settings.portsEnabled = true
      #expect(settings.showsPortsInSidebar == (placement != .network))
      #expect(settings.showsPortsInNetwork == (placement != .sidebar))
      settings.portsEnabled = false
      #expect(settings.portsPlacement == placement)
    }
  }

  @Test func movingPortsOutOfSidebarRedirectsCurrentAndExternalRoutes() {
    let settings = makeSettings()
    settings.portsEnabled = true
    settings.panelTab = .ports
    settings.portsPlacement = .network
    #expect(settings.panelTab == .network)
    settings.panelTab = .ports
    #expect(settings.panelTab == .network)
    #expect(AppDeepLink.page(.ports, settings: settings) == .network)
    settings.portsPlacement = .both
    settings.panelTab = .ports
    #expect(settings.panelTab == .ports)
    #expect(AppDeepLink.page(.ports, settings: settings) == .ports)
    settings.portsEnabled = false
    #expect(AppDeepLink.page(.ports, settings: settings) == .settingsFeatures)
  }

  @Test func placementPersistsAndRestoresSavedRoutes() throws {
    let suite = "PortsPlacement.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.portsEnabled = true
    settings.portsPlacement = .both
    #expect(AppSettings(defaults: defaults).portsPlacement == .both)
    defaults.set("network", forKey: "portsPlacement")
    defaults.set("ports", forKey: "panelTab")
    let restored = AppSettings(defaults: defaults)
    #expect(restored.portsPlacement == .network)
    #expect(restored.panelTab == .network)
    defaults.set("future-placement", forKey: "portsPlacement")
    let unknown = AppSettings(defaults: defaults)
    #expect(unknown.portsPlacement == .sidebar)
    #expect(unknown.panelTab == .ports)
  }

  @Test func placementBackupRoundTripsAndIgnoresMissingOrUnknownChoices() throws {
    let source = makeSettings()
    source.portsEnabled = true
    source.portsPlacement = .network
    let document = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(source.exportDocument()))
    let destination = makeSettings()
    destination.apply(document)
    #expect(destination.portsEnabled)
    #expect(destination.portsPlacement == .network)
    destination.apply(SettingsDocument())
    #expect(destination.portsPlacement == .network)
    var unknown = SettingsDocument()
    unknown.portsPlacement = "future-placement"
    destination.apply(unknown)
    #expect(destination.portsPlacement == .network)
  }

  @Test func demandTracksOnlyVisiblePortContentAndStopsWhenClosedOrDisabled() {
    let settings = makeSettings()
    settings.portsEnabled = true
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    model.isMainWindowVisible = true
    settings.panelTab = .ports
    #expect(model.portsVisible)
    model.isMainWindowVisible = false
    #expect(!model.portsVisible)
    model.isMainWindowVisible = true
    settings.portsPlacement = .network
    #expect(!model.portsVisible)
    for _ in 0..<5 {
      model.isPortsSheetPresented = true
      #expect(model.portsVisible)
      model.isMainWindowVisible = false
      #expect(!model.portsVisible)
      model.isMainWindowVisible = true
      model.isPortsSheetPresented = false
      #expect(!model.portsVisible)
    }
    model.isPortsSheetPresented = true
    settings.panelTab = .overview
    #expect(!model.portsVisible)
    settings.panelTab = .network
    #expect(model.portsVisible)
    settings.portsEnabled = false
    #expect(!model.portsVisible)
    settings.portsEnabled = true
    settings.portsPlacement = .sidebar
    #expect(!model.portsVisible)
    model.isPortsSheetPresented = false
    settings.portsPlacement = .both
    #expect(!model.portsVisible)
    settings.panelTab = .ports
    #expect(model.portsVisible)
  }

  @Test func portSheetSuspendsCoveredNetworkDetailsButKeepsIndependentPopoverDemand() {
    let settings = makeSettings()
    settings.portsEnabled = true
    settings.portsPlacement = .network
    settings.panelTab = .network
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    model.isMainWindowVisible = true
    #expect(model.isNetworkDetailVisible)
    for _ in 0..<5 {
      model.isPortsSheetPresented = true
      #expect(model.portsVisible && !model.isNetworkDetailVisible)
      model.openPopover = .network
      #expect(model.isNetworkDetailVisible)
      model.openPopover = nil
      #expect(!model.isNetworkDetailVisible)
      model.isPortsSheetPresented = false
      #expect(!model.portsVisible && model.isNetworkDetailVisible)
    }
    model.isPortsSheetPresented = true
    settings.portsEnabled = false
    #expect(!model.portsVisible && model.isNetworkDetailVisible)
    settings.portsEnabled = true
    settings.portsPlacement = .sidebar
    #expect(!model.portsVisible && model.isNetworkDetailVisible)
    model.isMainWindowVisible = false
    #expect(!model.portsVisible && !model.isNetworkDetailVisible)
    model.openPopover = .network
    #expect(model.isNetworkDetailVisible)
    settings.setModuleEnabled(.network, false)
    #expect(!model.isNetworkDetailVisible)
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

  @Test func socketReadFailureClearsCachedConnectionsAndRecovers() {
    let controller = PortsController()
    let sockets = [socket(pid: 10, port: 8080), socket(pid: 11, port: 8080)]
    let rates = [Int32(10): NetworkProcessRate(name: "proc", download: 1024, upload: 512)]
    controller.publish(sockets: sockets, rates: rates, sampler: NetworkProcessSampler())
    #expect(controller.sockets.count == 2 && controller.conflicts.count == 2)
    #expect(!controller.failed)

    controller.publish(sockets: nil, rates: rates, sampler: NetworkProcessSampler())
    #expect(controller.failed && controller.hasLoaded)
    #expect(controller.sockets.isEmpty && controller.rates.isEmpty && controller.conflicts.isEmpty)

    controller.publish(sockets: [sockets[0]], rates: [:], sampler: NetworkProcessSampler())
    #expect(!controller.failed && controller.sockets == [sockets[0]])
    #expect(controller.conflicts.isEmpty && controller.rates.isEmpty)
  }

  @Test func rateReadFailureDoesNotAttachCachedRatesToReusedPID() {
    let controller = PortsController()
    let previous = socket(pid: 10, name: "old", port: 8080)
    let rates = [Int32(10): NetworkProcessRate(name: "old", download: 1024, upload: 512)]
    controller.publish(sockets: [previous], rates: rates, sampler: NetworkProcessSampler())
    #expect(controller.rates[10]?.download == 1024)
    let replacement = socket(pid: 10, name: "new", port: 9000)
    for _ in 0..<3 {
      controller.publish(sockets: [replacement], rates: nil, sampler: NetworkProcessSampler())
      #expect(controller.rates.isEmpty)
      #expect(controller.sockets == [replacement] && !controller.failed)
    }
    let recovered = [Int32(10): NetworkProcessRate(name: "new", download: 128, upload: 0)]
    controller.publish(sockets: [replacement], rates: recovered, sampler: NetworkProcessSampler())
    #expect(controller.rates[10]?.name == "new" && controller.rates[10]?.download == 128)
  }

  @Test func pausingOrHidingPortContentDropsDisplayedRates() {
    let controller = PortsController()
    let sockets = [socket(pid: 10, port: 8080)]
    let rates = [Int32(10): NetworkProcessRate(name: "proc", download: 1024, upload: 512)]
    // 同一主 Actor 周期内关闭需求，采样任务还未运行；验证反复开关不会保留旧速率。
    for _ in 0..<5 {
      controller.setDemand(enabled: true, visible: true)
      controller.publish(sockets: sockets, rates: rates, sampler: NetworkProcessSampler())
      controller.setPaused(true)
      #expect(controller.rates.isEmpty)
      controller.setDemand(enabled: true, visible: false)
      controller.setPaused(false)
      controller.setDemand(enabled: true, visible: true)
      controller.publish(sockets: sockets, rates: rates, sampler: NetworkProcessSampler())
      controller.setDemand(enabled: true, visible: false)
      #expect(controller.rates.isEmpty)
    }
    controller.setDemand(enabled: false, visible: false)
    #expect(controller.sockets.isEmpty && !controller.hasLoaded)
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
