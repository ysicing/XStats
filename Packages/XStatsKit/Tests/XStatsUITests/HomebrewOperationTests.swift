// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner
@testable import XStatsUI

@MainActor
struct HomebrewOperationTests {
  private let package = HomebrewPackage(
    name: "redis", displayName: "redis", kind: .formula, installedVersions: ["1"],
    latestVersion: "2", outdated: true, pinned: false, installationURLs: [], applicationURLs: [])

  @Test(arguments: [HomebrewManagement.Action.upgrade, .uninstall])
  func packageWriteBlocksServiceAfterLeavingItsPage(_ action: HomebrewManagement.Action)
    async throws
  {
    let state = HomebrewOperationState()
    let fixture = HomebrewWriteFixture()
    let apps = makeApps(state: state, fixture: fixture)
    let services = makeServices(state: state, fixture: fixture)
    apps.setVisible(true, tab: .homebrew)
    services.setVisible(true)
    await waitUntil { !apps.isReading && !services.isLoading }
    let service = try #require(services.services.first)

    apps.perform(action, package: package)
    apps.setVisible(false)
    services.perform(.start, service: service)
    #expect(services.working == nil)
    #expect(state.isRunning)
    await waitUntil { await fixture.calls.contains("package") }
    await fixture.finishAll()
    await waitUntil { apps.operation == nil && services.working == nil }
    #expect(await fixture.calls == ["package"])
    #expect(!state.isRunning)

    services.perform(.start, service: service)
    await waitUntil { await fixture.calls.count >= 2 && services.working == nil }
    #expect(await fixture.calls == ["package", "service"])
    services.setVisible(false)
  }

  @Test(arguments: [HomebrewServices.Action.start, .stop, .restart])
  func serviceWriteBlocksPackageAndIndexAfterLeavingItsPage(_ action: HomebrewServices.Action)
    async throws
  {
    let state = HomebrewOperationState()
    let fixture = HomebrewWriteFixture()
    let apps = makeApps(state: state, fixture: fixture)
    let services = makeServices(state: state, fixture: fixture)
    apps.setVisible(true, tab: .homebrew)
    services.setVisible(true)
    await waitUntil { !apps.isReading && !services.isLoading }
    let service = try #require(services.services.first)

    services.perform(action, service: service)
    services.setVisible(false)
    apps.perform(.uninstall, package: package)
    apps.checkBrewUpdates()
    #expect(apps.operation == nil && !apps.isCheckingUpdates)
    #expect(state.isRunning)
    await waitUntil { await fixture.calls.contains("service") }
    await fixture.finishAll()
    await waitUntil { services.working == nil && apps.operation == nil && !apps.isCheckingUpdates }
    #expect(await fixture.calls == ["service"])
    #expect(!state.isRunning)

    apps.perform(.upgrade, package: package)
    await waitUntil { await fixture.calls.count >= 2 && apps.operation == nil }
    #expect(await fixture.calls == ["service", "package"])
    apps.setVisible(false)
  }

  @Test func indexUpdateBlocksServicesUntilItFinishes() async throws {
    let state = HomebrewOperationState()
    let fixture = HomebrewWriteFixture()
    let apps = makeApps(state: state, fixture: fixture)
    let services = makeServices(state: state, fixture: fixture)
    apps.setVisible(true, tab: .homebrew)
    services.setVisible(true)
    await waitUntil { !apps.isReading && !services.isLoading }
    let service = try #require(services.services.first)
    apps.checkBrewUpdates()
    apps.setVisible(false)
    services.perform(.start, service: service)
    #expect(services.working == nil && state.isRunning)
    await waitUntil { await fixture.calls.contains("index") }
    await fixture.finishAll()
    await waitUntil { !apps.isCheckingUpdates && services.working == nil }
    #expect(await fixture.calls == ["index"])
    #expect(!state.isRunning)
    services.setVisible(false)
  }

  @Test(arguments: ["package", "service", "index"], [false, true])
  func failedAndCancelledWritesReleaseTheOtherPage(_ operation: String, cancelled: Bool)
    async throws
  {
    let state = HomebrewOperationState()
    let fixture = HomebrewWriteFixture()
    let apps = makeApps(state: state, fixture: fixture)
    let services = makeServices(state: state, fixture: fixture)
    apps.setVisible(true, tab: .homebrew)
    services.setVisible(true)
    await waitUntil { !apps.isReading && !services.isLoading }
    let service = try #require(services.services.first)
    switch operation {
    case "package": apps.perform(.uninstall, package: package)
    case "service": services.perform(.start, service: service)
    default: apps.checkBrewUpdates()
    }
    #expect(state.isRunning)
    await waitUntil { await fixture.calls.contains(operation) }
    apps.setVisible(false)
    services.setVisible(false)
    if cancelled {
      await fixture.finishAll(error: CancellationError())
    } else {
      await fixture.finishAll(error: URLError(.cannotLoadFromNetwork))
    }
    await waitUntil {
      apps.operation == nil && !apps.isCheckingUpdates && services.working == nil
    }
    #expect(!state.isRunning)
    #expect(apps.error != nil || services.error != nil)

    // 失败的页面可以隐藏；另一页重新展示后应能发起正常操作。
    await fixture.finishAll()
    if operation == "service" {
      apps.setVisible(true, tab: .homebrew)
      await waitUntil { !apps.isReading }
      apps.perform(.upgrade, package: package)
    } else {
      services.setVisible(true)
      await waitUntil { !services.isLoading }
      services.perform(.start, service: service)
    }
    await waitUntil { await fixture.calls.count == 2 }
    await waitUntil { apps.operation == nil && services.working == nil }
    #expect(!state.isRunning)
    apps.setVisible(false)
    services.setVisible(false)
  }

  @Test func appModelSharesOneHomebrewWriteState() throws {
    let suite = "HomebrewOperationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil, aiUsageProviders: [],
      aiQuotaProviders: [])
    #expect(model.appManagement.homebrewOperations === model.homebrewServices.homebrewOperations)
  }

  @Test(arguments: ["package", "service"])
  func timedOutWriteKeepsOtherPageBlockedUntilActualExit(_ operation: String) async throws {
    let state = HomebrewOperationState()
    let fixture = HomebrewWriteFixture()
    let exit = HomebrewWriteFixture()
    let completion = Task<Void, Never> { _ = try? await exit.perform("exit") }
    let apps = makeApps(state: state, fixture: fixture)
    let services = makeServices(state: state, fixture: fixture)
    apps.setVisible(true, tab: .homebrew)
    services.setVisible(true)
    await waitUntil { !apps.isReading && !services.isLoading }
    await waitUntil { await exit.calls == ["exit"] }
    let service = try #require(services.services.first)
    if operation == "package" {
      apps.perform(.upgrade, package: package)
    } else {
      services.perform(.restart, service: service)
    }
    await waitUntil { await fixture.calls == [operation] }
    await fixture.finishAll(error: HomebrewOperationTimeout(completion: completion))
    await waitUntil { apps.error != nil || services.error != nil }
    #expect(state.isRunning)
    #expect(apps.completion == nil && services.completion == nil)
    #expect(operation == "package" ? apps.operation != nil : services.working != nil)

    apps.setVisible(false)
    services.setVisible(false)
    apps.setPaused(true)
    services.setPaused(true)
    #expect(state.isRunning)
    apps.setPaused(false)
    services.setPaused(false)
    apps.setVisible(true, tab: .homebrew)
    services.setVisible(true)
    await waitUntil { !apps.isReading && !services.isLoading }
    apps.perform(.uninstall, package: package)
    apps.checkBrewUpdates()
    services.perform(.start, service: service)
    #expect(await fixture.calls == [operation])
    #expect(state.isRunning && !apps.isCheckingUpdates)

    await exit.finishAll()
    await waitUntil { !state.isRunning && apps.operation == nil && services.working == nil }
    #expect(apps.completion == nil && services.completion == nil)
    apps.setVisible(false)
    services.setVisible(false)
  }

  private func makeApps(
    state: HomebrewOperationState, fixture: HomebrewWriteFixture
  ) -> AppManagementController {
    let package = package
    return AppManagementController(
      listApps: { [] }, brewAvailable: true, listPackages: { [package] },
      updateIndex: { try await fixture.perform("index") },
      performAction: { _, _ in try await fixture.perform("package") },
      homebrewOperations: state)
  }

  private func makeServices(
    state: HomebrewOperationState, fixture: HomebrewWriteFixture
  ) -> HomebrewServicesController {
    HomebrewServicesController(
      brewAvailable: { true },
      readInventory: {
        try HomebrewServices.parse(#"[{"name":"redis","status":"none"}]"#)
      },
      performAction: { _, _ in try await fixture.perform("service") },
      homebrewOperations: state)
  }

  private func waitUntil(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
    #expect(await condition())
  }
}

private actor HomebrewWriteFixture {
  private(set) var calls: [String] = []
  private var pending: [CheckedContinuation<Void, any Error>] = []
  private var finished = false
  private var error: (any Error)?

  func perform(_ operation: String) async throws {
    calls.append(operation)
    if finished {
      if let error { throw error }
      return
    }
    try await withCheckedThrowingContinuation { pending.append($0) }
  }

  func finishAll(error: (any Error)? = nil) {
    finished = true
    self.error = error
    for continuation in pending {
      if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    pending = []
  }
}
