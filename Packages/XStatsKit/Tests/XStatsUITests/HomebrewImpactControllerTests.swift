// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner
@testable import XStatsUI

@MainActor
struct HomebrewImpactControllerTests {
  private let package = HomebrewPackage(
    name: "tool", displayName: "Tool", kind: .formula, installedVersions: ["1"],
    latestVersion: "2", outdated: true, pinned: false, installationURLs: [], applicationURLs: [])

  @Test(arguments: [false, true])
  func directUpgradeDoesNotRequireASuccessfulPreview(requestPreview: Bool) async throws {
    let fixture = package
    let gate = ImpactPreviewTestGate()
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true, listPackages: { [fixture] },
      performAction: { _, _ in await gate.write() },
      prepareAction: { _, _ in
        #expect(requestPreview)
        throw URLError(.cannotParseResponse)
      })
    controller.setVisible(true, tab: .homebrew)
    defer { controller.setVisible(false) }
    try await waitFor { !controller.isLoadingBrew && !controller.packages.isEmpty }
    if requestPreview {
      controller.preparePreview(.upgrade, package: fixture)
      try await waitFor { !controller.isPreparingPreview }
      #expect(controller.previewError != nil)
    }
    #expect(controller.impactPreview == nil)
    #expect(controller.perform(.upgrade, package: fixture))
    #expect(!controller.perform(.upgrade, package: fixture))
    controller.setVisible(false)
    try await waitFor { controller.operation == nil }
    #expect(await gate.writes == 1)
  }

  @Test func cancellingRejectsLatePreviewAndHoldsTheGateUntilTheReadExits() async throws {
    let gate = ImpactPreviewTestGate()
    let state = HomebrewOperationState()
    let controller = makeController(gate: gate, state: state)
    controller.setVisible(true, tab: .homebrew)
    defer { controller.setVisible(false) }
    try await waitFor { !controller.isLoadingBrew && !controller.packages.isEmpty }
    controller.preparePreview(.upgrade, package: package)
    try await waitFor { await gate.started }
    #expect(state.isRunning)
    controller.cancelPreview()
    #expect(state.isRunning && controller.impactPreview == nil)
    #expect(controller.previewError == nil)
    #expect(!controller.perform(.upgrade, package: package))
    let rejection = try #require(controller.previewError)
    #expect(controller.operation == nil)
    await gate.release()
    try await waitFor { !state.isRunning }
    #expect(controller.impactPreview == nil && controller.previewError == rejection)
    #expect(await gate.writes == 0)
  }

  @Test(arguments: [false, true])
  func hidingOrPausingDiscardsThePreview(_ pause: Bool) async throws {
    let gate = ImpactPreviewTestGate()
    let state = HomebrewOperationState()
    let controller = makeController(gate: gate, state: state)
    controller.setVisible(true, tab: .homebrew)
    defer { controller.setVisible(false) }
    try await waitFor { !controller.isLoadingBrew && !controller.packages.isEmpty }
    controller.preparePreview(.upgrade, package: package)
    try await waitFor { await gate.started }
    if pause { controller.setPaused(true) } else { controller.setVisible(false) }
    await gate.release()
    try await waitFor { !state.isRunning }
    #expect(controller.impactPreview == nil && !controller.isPreparingPreview)
  }

  @Test func failedAndBlockedPreviewsCannotAuthorizeWrites() async throws {
    let fixture = package
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true, listPackages: { [fixture] },
      performAction: { _, _ in Issue.record("A blocked preview must not authorize a write") },
      prepareAction: { action, package in
        if action == .upgrade { throw URLError(.cannotParseResponse) }
        return HomebrewImpactPreview(
          package: package, action: action, output: "", dependents: ["editor"])
      })
    controller.setVisible(true, tab: .homebrew)
    defer { controller.setVisible(false) }
    try await waitFor { !controller.isLoadingBrew && !controller.packages.isEmpty }
    controller.preparePreview(.upgrade, package: package)
    try await waitFor { !controller.isPreparingPreview }
    #expect(controller.previewError != nil && controller.impactPreview == nil)
    controller.preparePreview(.uninstall, package: package)
    try await waitFor { !controller.isPreparingPreview }
    let blocked = try #require(controller.impactPreview)
    #expect(!controller.performPreviewedAction(blocked))
    #expect(controller.operation == nil)
  }

  @Test func confirmedPreviewRunsOnceAndStillFinishesAfterThePageCloses() async throws {
    let gate = ImpactPreviewTestGate()
    await gate.release()
    let state = HomebrewOperationState()
    let controller = makeController(gate: gate, state: state)
    controller.setVisible(true, tab: .homebrew)
    try await waitFor { !controller.isLoadingBrew && !controller.packages.isEmpty }
    controller.preparePreview(.upgrade, package: package)
    try await waitFor { !controller.isPreparingPreview }
    let ready = try #require(controller.impactPreview)
    #expect(controller.performPreviewedAction(ready))
    #expect(!controller.performPreviewedAction(ready))
    controller.setVisible(false)
    try await waitFor { controller.operation == nil }
    #expect(await gate.writes == 1)
    #expect(!state.isRunning)
  }

  @Test func sourceEvidenceUsesArtifactPathsAndReceiptsRatherThanNames() throws {
    let app = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/Editor.app"), name: "Editor",
      bundleIdentifier: "test.editor", version: "1", teamIdentifier: nil)
    let sameName = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/Other/Editor.app"), name: "Editor",
      bundleIdentifier: "test.editor", version: "1", teamIdentifier: nil)
    let cask = try #require(
      HomebrewManagement.parse(
        #"{"formulae":[],"casks":[{"full_token":"vendor/apps/editor","installed":"1","artifacts":[{"app":["Editor.app"],"target":"/Applications/Editor.app"}]}]}"#,
        prefix: URL(fileURLWithPath: "/opt/homebrew")
      ).first)
    let controller = AppManagementController(brewAvailable: true)
    controller.showPreview(
      apps: [app, sameName], metadata: [:], sizes: [:], packages: [cask])
    #expect(controller.installationSource(for: app) == .homebrew(cask, app.url))
    #expect(controller.installationSource(for: sameName) == .unknown)
    controller.showPreview(
      apps: [app], metadata: [app.id: ApplicationMetadata(isAppStore: true)],
      sizes: [:], packages: [])
    #expect(
      controller.installationSource(for: app)
        == .appStore(app.url.appendingPathComponent("Contents/_MASReceipt/receipt")))
  }

  @Test(arguments: [
    "work.12306.xstats.app", "work.12306.xstats.capture", "work.12306.xstats.networkmonitor",
  ])
  func xstatsSourceUsesExactApplicationIdentifiers(bundleIdentifier: String) {
    let app = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/Renamed.app"), name: "Renamed",
      bundleIdentifier: bundleIdentifier, version: "1", teamIdentifier: nil)
    let controller = AppManagementController(brewAvailable: false)
    controller.showPreview(apps: [app], metadata: [:], sizes: [:], packages: [])
    #expect(controller.installationSource(for: app) == .xstats(bundleIdentifier))
    #expect(controller.installationSource(for: app).title == "ysicing")
    controller.showPreview(
      apps: [app], metadata: [app.id: ApplicationMetadata(isAppStore: true)],
      sizes: [:], packages: [])
    #expect(
      controller.installationSource(for: app)
        == .appStore(app.url.appendingPathComponent("Contents/_MASReceipt/receipt")))
  }

  @Test(arguments: [
    "test.xstats", "work.12306.xstats.app.other", "work.12306.xstats.helper",
  ])
  func unknownSourceDoesNotGuessFromApplicationNameOrIdentifierPrefix(bundleIdentifier: String) {
    let app = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/XStats.app"), name: "XStats",
      bundleIdentifier: bundleIdentifier, version: "1", teamIdentifier: nil)
    let controller = AppManagementController(brewAvailable: false)
    #expect(controller.installationSource(for: app) == .unknown)
    #expect(controller.installationSource(for: app).title == "-")
  }

  private func makeController(
    gate: ImpactPreviewTestGate, state: HomebrewOperationState
  ) -> AppManagementController {
    let fixture = package
    return AppManagementController(
      listApps: { [] }, brewAvailable: true, listPackages: { [fixture] },
      performAction: { _, _ in await gate.write() },
      prepareAction: { action, package in
        await gate.wait()
        return HomebrewImpactPreview(
          package: package, action: action, output: "Would upgrade tool 1 -> 2")
      }, homebrewOperations: state)
  }

  private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await condition())
  }
}

private actor ImpactPreviewTestGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var started = false
  private(set) var writes = 0

  func wait() async {
    started = true
    if !released { await withCheckedContinuation { continuation = $0 } }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }

  func write() { writes += 1 }
}
