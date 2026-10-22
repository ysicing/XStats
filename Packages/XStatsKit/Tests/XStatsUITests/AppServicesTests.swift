// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import Cleaner
@testable import XStatsUI

@MainActor
struct AppServicesTests {
  @Test func legacyRouteAndSavedSectionResolveToOneEntry() throws {
    let suite = "AppServicesTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("startupItems", forKey: "panelTab")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.panelTab == .uninstaller)
    #expect(settings.appServicesSection == .startup)
    #expect(!PanelTab.tools.contains(.startupItems))
    #expect(PanelTab.tools.filter { $0 == .uninstaller }.count == 1)
    #expect(defaults.string(forKey: "panelTab") == PanelTab.uninstaller.rawValue)
    settings.appServicesSection = .services
    #expect(AppSettings(defaults: defaults).appServicesSection == .services)
    #expect(AppDeepLink.page(.startupItems, settings: settings) == .uninstaller)
    #expect(settings.appServicesSection == .startup)
    settings.appServicesSection = .homebrew
    settings.panelTab = .startupItems
    #expect(settings.panelTab == .uninstaller)
    #expect(settings.appServicesSection == .startup)
  }

  @Test func legacyOptOutDoesNotRestrictAnyCategory() throws {
    let suite = "AppServicesTests.disabled.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "uninstallerEnabled")
    defaults.set(PanelTab.uninstaller.rawValue, forKey: "panelTab")
    let settings = AppSettings(defaults: defaults)
    for section in AppServicesSection.allCases {
      settings.appServicesSection = section
      #expect(settings.appServicesSection == section)
      let reloaded = AppSettings(defaults: defaults)
      #expect(reloaded.panelTab == .uninstaller)
      #expect(reloaded.appServicesSection == section)
    }
  }

  @Test func startupIncludesDaemonsAndHomebrewServicesDoNotScanLaunchd() {
    let items = LaunchItem.Scope.allCases.map { scope in
      LaunchItem(
        label: "test.\(scope.rawValue)",
        plist: URL(fileURLWithPath: scope.directory + "/example.plist"), scope: scope,
        program: "/Applications/Example.app/Contents/MacOS/agent", runAtLoad: true,
        keepAlive: false, disabledInPlist: false)
    }
    #expect(AppServicesSection.startup.launchScopes == [.user, .allUsers, .system])
    #expect(AppServicesSection.services.launchScopes.isEmpty)
    #expect(
      StartupItemsPage.filteredItems(items, section: .startup, scope: .system, search: "").count
        == 1)
    #expect(
      StartupItemsPage.filteredItems(items, section: .services, scope: .user, search: "").isEmpty)
    #expect(
      StartupItemsPage.filteredItems(items, section: .startup, scope: .user, search: "EXAMPLE")
        .count == 1)
    #expect(
      StartupItemsPage.filteredItems(
        items, section: .startup, scope: .system, search: "test.system"
      ).count == 1)
    #expect(
      StartupItemsPage.filteredItems(items, section: .startup, scope: .allUsers, search: "missing")
        .isEmpty)
  }

  @Test func leavingDuringCategoryChangeDoesNotRestartHiddenApplicationReads() async throws {
    let suite = "AppServicesTests.navigation.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.panelTab = .uninstaller
    settings.appServicesSection = .startup
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    model.isMainWindowVisible = true
    model.appManagement.showPreview(apps: [], metadata: [:], sizes: [:], packages: [])
    defer {
      model.appManagement.setVisible(false)
      model.uninstaller.setEnabled(false)
    }
    let host = NSHostingView(rootView: AppServicesNavigationTestHost(model: model))
    let window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 700),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(100))

    // 先触发分类的布局更新，再在延迟任务恢复前切走；不启动真实清单扫描。
    settings.appServicesSection = .apps
    host.layoutSubtreeIfNeeded()
    settings.panelTab = .cpu
    host.layoutSubtreeIfNeeded()
    for _ in 0..<10 { await Task.yield() }
    model.appManagement.refresh()
    #expect(!model.appManagement.isReading)
    model.appManagement.setVisible(false)
  }

  @Test func closingAndPausingDiscardReadsAndDoNotStartHiddenWork() async throws {
    let gate = AppServicesReadGate()
    let controller = StartupItemsController(readInventory: { await gate.read($0) })
    controller.refresh()
    #expect(!controller.isLoading)
    #expect(await gate.calls == 0)
    controller.setVisible(true)
    await waitForCalls(1, gate: gate)
    controller.setVisible(false)
    #expect(!controller.isLoading)
    await gate.finish()
    for _ in 0..<10 { await Task.yield() }
    #expect(controller.items.isEmpty)
    controller.setPaused(true)
    controller.setVisible(true)
    #expect(!controller.isLoading)
    controller.setPaused(false)
    await waitForCalls(2, gate: gate)
    await gate.finish()
    let deadline = ContinuousClock.now + .seconds(5)
    while controller.isLoading, ContinuousClock.now < deadline { await Task.yield() }
    #expect(!controller.isLoading)
    #expect(controller.items.count == 1)
    controller.setVisible(false)
    controller.refresh()
    #expect(await gate.calls == 2)
  }

  @Test func rapidCategoryChangesRejectOldReadsAndLimitScopes() async {
    let first = AppServicesReadGate()
    let third = AppServicesReadGate()
    let controller = StartupItemsController { scopes in
      if await first.calls == 0 { return await first.read(scopes) }
      return await third.read(scopes)
    }
    controller.setVisible(true, section: .startup)
    await waitForCalls(1, gate: first)
    controller.setVisible(true, section: .services)
    #expect(!controller.isLoading)
    controller.setVisible(true, section: .startup)
    await waitForCalls(1, gate: third)
    await first.finish()
    for _ in 0..<10 { await Task.yield() }
    #expect(controller.items.isEmpty && controller.isLoading)
    await third.finish()
    let deadline = ContinuousClock.now + .seconds(5)
    while controller.isLoading, ContinuousClock.now < deadline { await Task.yield() }
    #expect(controller.items.count == 1 && !controller.isLoading)
    #expect(await first.scopes == [.user, .allUsers, .system])
    #expect(await third.scopes == [.user, .allUsers, .system])
    controller.setVisible(false)
  }

  private func waitForCalls(_ count: Int, gate: AppServicesReadGate) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while await gate.calls < count, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await gate.calls == count)
  }
}

private struct AppServicesNavigationTestHost: View {
  let model: AppModel

  var body: some View {
    Group {
      if model.settings.panelTab == .uninstaller {
        AppManagementPage().environment(model).environment(\.isSnapshot, true)
      } else {
        Color.clear
      }
    }
    .frame(width: 800, height: 700)
  }
}

private actor AppServicesReadGate {
  private(set) var calls = 0
  private(set) var scopes: [LaunchItem.Scope] = []
  private var pending: CheckedContinuation<([LaunchItem], LaunchStatus), Never>?

  func read(_ scopes: [LaunchItem.Scope]) async -> ([LaunchItem], LaunchStatus) {
    self.scopes = scopes
    calls += 1
    return await withCheckedContinuation { pending = $0 }
  }

  func finish() {
    pending?.resume(
      returning: (
        [
          LaunchItem(
            label: "test.agent", plist: URL(fileURLWithPath: "/tmp/test.agent.plist"), scope: .user,
            program: nil, runAtLoad: true, keepAlive: false, disabledInPlist: false)
        ], LaunchStatus()
      ))
    pending = nil
  }
}
