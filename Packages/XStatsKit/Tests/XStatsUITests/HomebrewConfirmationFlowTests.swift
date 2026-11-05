// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI
import Testing
@testable import Cleaner
@testable import XStatsUI

@MainActor
struct HomebrewConfirmationFlowTests {
  enum PreviewChoice: String, CaseIterable, Sendable { case skip, show, fail }
  enum ConfirmationBlock: CaseIterable, Sendable { case indexUpdate, packageWrite, stalePackage }

  @Test(arguments: ConfirmationBlock.allCases)
  func unavailableUpgradeCannotConfirmAndExplainsRejectedExecution(block: ConfirmationBlock)
    async throws
  {
    let package = try #require(
      HomebrewManagement.parse(
        #"{"formulae":[{"name":"tool","full_name":"tool","installed":[{"version":"1"}],"outdated":true}],"casks":[]}"#,
        prefix: URL(fileURLWithPath: "/opt/homebrew")
      ).first)
    let (events, release) = AsyncStream<Void>.makeStream()
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true, listPackages: { [package] },
      updateIndex: { for await _ in events {} },
      performAction: { _, _ in for await _ in events {} })
    controller.setVisible(true, tab: .homebrew)
    defer {
      release.finish()
      controller.setVisible(false)
    }
    try await waitFor { !controller.isLoadingBrew && !controller.packages.isEmpty }
    let sheet = HomebrewConfirmationSheet(
      controller: controller, confirmation: BrewConfirmation(package: package, action: .upgrade),
      confirm: {}, cancel: {})
    #expect(sheet.canConfirm)
    switch block {
    case .indexUpdate:
      controller.checkBrewUpdates()
      #expect(controller.isCheckingUpdates)
    case .packageWrite:
      try #require(controller.perform(.upgrade, package: package))
      #expect(controller.operation != nil)
    case .stalePackage:
      controller.showPreview(apps: [], metadata: [:], sizes: [:], packages: [])
    }
    #expect(!sheet.canConfirm)
    #expect(!controller.perform(.upgrade, package: package))
    #expect(controller.previewError != nil)
    release.finish()
    try await waitFor { controller.operation == nil && !controller.isCheckingUpdates }
  }

  @Test(arguments: PreviewChoice.allCases)
  func upgradeConfirmationLoadsOnlyRequestedPreviews(choice: PreviewChoice) async throws {
    _ = NSApplication.shared
    let package = try #require(
      HomebrewManagement.parse(
        #"{"formulae":[{"name":"buildkit","full_name":"buildkit","installed":[{"version":"0.34.1"}],"outdated":true,"versions":{"stable":"0.34.2"}}],"casks":[]}"#,
        prefix: URL(fileURLWithPath: "/opt/homebrew")
      ).first)
    let actions = ConfirmationTestActions()
    let controller = AppManagementController(
      listApps: { [] }, brewAvailable: true, listPackages: { [package] },
      performAction: { _, _ in await actions.perform() },
      prepareAction: { action, package in
        try await actions.prepare(action: action, package: package, fails: choice == .fail)
      })
    controller.setVisible(true, tab: .homebrew)
    defer { controller.setVisible(false) }
    try await waitFor { !controller.isLoadingBrew && !controller.packages.isEmpty }
    let suite = "HomebrewConfirmationFlowTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      magpieClient: UnavailableMagpieClient())
    let sheet = HomebrewConfirmationSheet(
      controller: controller,
      confirmation: BrewConfirmation(package: package, action: .upgrade),
      confirm: { controller.perform(.upgrade, package: package) }, cancel: {},
      showsPreview: choice != .skip)
    let host = NSHostingView(
      rootView: sheet.environment(model)
        .environment(\.colorScheme, .light)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 520, height: 260),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    if choice == .skip {
      #expect(await actions.previews == 0)
      #expect(controller.previewError == nil)
      #expect(host.fittingSize.height < 300)
      try saveSnapshot(host, name: "upgrade-compact")
    } else {
      try await waitFor {
        !controller.isPreparingPreview
          && (controller.previewError != nil || controller.impactPreview != nil)
      }
      #expect(await actions.previews == 1)
      #expect((controller.previewError != nil) == (choice == .fail))
      host.layoutSubtreeIfNeeded()
      try saveSnapshot(host, name: "upgrade-preview-\(choice.rawValue)")
    }
    #expect(sheet.canConfirm)
    sheet.confirm()
    try await waitFor { await actions.writes == 1 && controller.operation == nil }
    #expect(await actions.previews == (choice == .skip ? 0 : 1))
    #expect(!controller.homebrewOperations.isRunning)
  }

  @Test(arguments: [false, true])
  func selectedRowKeepsItsUpdateActionReadable(dark: Bool) throws {
    _ = NSApplication.shared
    let row = SelectionTestRow(id: "buildkit")
    let content = Table([row], selection: .constant(Optional(row.id))) {
      TableColumn("Name") { _ in Text("buildkit") }.width(130)
      TableColumn("Version") { _ in
        HStack {
          Text("0.34.1").foregroundStyle(.secondary)
          Text("→").foregroundStyle(.tertiary)
          Text("0.34.2")
          AppManagementUpdateButton(isSelected: true) {}
        }
      }.width(240)
      TableColumn("Source") { _ in
        InstallationSourceButton(label: "homebrew/core", evidence: .unknown)
      }.width(160)
      TableColumn("Description") { _ in
        Text("Concurrent, cache-efficient build toolkit").foregroundStyle(.secondary)
      }
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
    .dsFont(.sm)
    .frame(width: 1050, height: 125)
    .environment(\.colorScheme, dark ? .dark : .light)
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 1050, height: 125),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    for table in descendants(host).compactMap({ $0 as? NSTableView }) {
      table.rowView(atRow: 0, makeIfNecessary: true)?.isEmphasized = true
      for cell in descendants(table).compactMap({ $0 as? NSTableCellView }) {
        cell.backgroundStyle = .emphasized
      }
    }
    try saveSnapshot(host, name: "selected-row-\(dark ? "dark" : "light")")
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }

  private func saveSnapshot(_ host: NSView, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["XSTATS_HOMEBREW_PREVIEW_DIR"] else {
      return
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    host.window?.setContentSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    try #require(image.representation(using: .png, properties: [:])).write(
      to: directory.appendingPathComponent("\(name).png"))
  }

  private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await condition())
  }
}

private struct SelectionTestRow: Identifiable {
  let id: String
}

private actor ConfirmationTestActions {
  private(set) var previews = 0
  private(set) var writes = 0

  func prepare(
    action: HomebrewManagement.Action, package: HomebrewPackage, fails: Bool
  ) throws -> HomebrewImpactPreview {
    previews += 1
    if fails { throw URLError(.cannotParseResponse) }
    return HomebrewImpactPreview(
      package: package, action: action,
      output: "==> Would upgrade 1 requested outdated package\nbuildkit 0.34.1 -> 0.34.2 (8.3MB)")
  }

  func perform() { writes += 1 }
}
