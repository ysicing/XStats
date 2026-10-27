// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct ProcessNavigationTests {
  @Test func portNavigationReleasesSheetDemandAndSelectsOnlyItsOwner() throws {
    let suite = "ProcessNavigationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.processesEnabled = true
    settings.portsEnabled = true
    settings.portsPlacement = .network
    settings.panelTab = .network
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    model.isMainWindowVisible = true
    model.isPortsSheetPresented = true
    #expect(model.portsVisible)
    let socket = PortSocket(
      pid: 42, name: "worker", appBundlePath: "/Applications/Example.app", uid: getuid(),
      socketID: 1, transport: .tcp, state: .listening, localAddress: nil, localPort: 8080)

    model.showProcesses(.portOwner(socket))

    #expect(settings.panelTab == .processes)
    #expect(!model.portsVisible && !model.isPortsSheetPresented)
    let target = try #require(model.processNavigationTarget)
    var process = ProcessUsage(
      pid: 42, name: "worker", executablePath: nil,
      appBundlePath: "/Applications/Example.app", cpu: 0, memory: 0)
    process.uid = getuid()
    #expect(target.matches(process))
    #expect(target.selection == "pid-42")
    process = ProcessUsage(
      pid: 142, name: "worker", executablePath: nil,
      appBundlePath: "/Applications/Example.app", cpu: 0, memory: 0)
    process.uid = getuid()
    #expect(!target.matches(process))
    var replaced = ProcessUsage(
      pid: 42, name: "other", executablePath: nil,
      appBundlePath: "/Applications/Other.app", cpu: 0, memory: 0)
    replaced.uid = getuid()
    #expect(!target.matches(replaced))
  }

  @Test func applicationNavigationMatchesBundlePathInsteadOfDisplayName() {
    let target = ProcessNavigationTarget.application("/Applications/Example.app")
    let helper = ProcessUsage(
      pid: 42, name: "Example Helper", executablePath: nil,
      appBundlePath: "/Applications/Example.app", cpu: 0, memory: 0)
    let otherCopy = ProcessUsage(
      pid: 43, name: "Example Helper", executablePath: nil,
      appBundlePath: "/Users/test/Applications/Example.app", cpu: 0, memory: 0)
    #expect(target.matches(helper))
    #expect(!target.matches(otherCopy))
    #expect(target.selection == nil)
  }

  @Test func disabledProcessFeatureRoutesToSettingsWithoutEnablingOrRetainingTarget() throws {
    let suite = "ProcessNavigationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    var opened: PanelTab?
    model.openMainWindow = { opened = $0 }
    model.showProcesses(.application("/Applications/Example.app"))
    #expect(!settings.processesEnabled)
    #expect(settings.panelTab == .settingsFeatures && opened == .settingsFeatures)
    #expect(model.featureSettingsTab == .optional)
    #expect(model.processNavigationTarget == nil)
    #expect(!model.demand.systemProcesses)
  }

  @Test(arguments: ["/Applications/Example.app", "/Applications/Tools/Example.app"])
  func applicationDestinationSelectsAppsWithoutStartingHiddenInventory(_ path: String) throws {
    let suite = "ProcessNavigationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.appServicesSection = .services
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    var opened: PanelTab?
    model.openMainWindow = { opened = $0 }
    #expect(AppModel.supportsApplicationNavigation(path))
    model.showApplication(path)
    #expect(settings.appServicesSection == .apps)
    #expect(settings.panelTab == .uninstaller && opened == .uninstaller)
    #expect(model.applicationNavigationPath == path)
    #expect(!model.appManagement.visible)
  }

  @Test(arguments: [
    "/System/Applications/Utilities/Terminal.app",
    "/Users/demo/Downloads/Example.app",
    "/Applications/Tools/Nested/Example.app",
    "/Applications/Example.app/Contents/Helper.app",
    "/Applications/.Hidden/Example.app",
    "/Applications/Tools",
  ])
  func applicationOutsideInventoryDoesNotLeaveTheProcessPage(_ path: String) throws {
    let suite = "ProcessNavigationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.processesEnabled = true
    settings.panelTab = .processes
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    var opened: PanelTab?
    model.openMainWindow = { opened = $0 }
    #expect(!AppModel.supportsApplicationNavigation(path))
    model.showApplication(path)
    #expect(settings.panelTab == .processes)
    #expect(model.applicationNavigationPath == nil && opened == nil)
    #expect(!model.appManagement.visible)
  }

  @Test func userApplicationsFollowTheSameInventoryDepthWithoutReadingTheDirectory() {
    #expect(
      AppModel.supportsApplicationNavigation(
        "/Users/demo/Applications/Example.app", home: "/Users/demo"))
    #expect(
      AppModel.supportsApplicationNavigation(
        "/Users/demo/Applications/Tools/Example.app", home: "/Users/demo"))
    #expect(
      !AppModel.supportsApplicationNavigation(
        "/Users/demo/Applications/Tools/Nested/Example.app", home: "/Users/demo"))
    #expect(!AppModel.supportsApplicationNavigation(nil))
  }
}
