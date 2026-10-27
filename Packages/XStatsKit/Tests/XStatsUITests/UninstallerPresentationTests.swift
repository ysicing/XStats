// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct UninstallerPresentationTests {
  @Test func scanStagesKeepInspectorSizedAndRemovalDisabled() async throws {
    let suite = "UninstallerProgressPresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      magpieClient: UnavailableMagpieClient())
    defer { model.uninstaller.setEnabled(false) }
    let app = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/Progress Demo.app"), name: "Progress Demo",
      bundleIdentifier: "test.uninstall.progress", version: "1.0", teamIdentifier: nil)
    let items = [
      AppLeftover(url: app.url, kind: .application, size: 20_000_000),
      AppLeftover(
        url: URL(fileURLWithPath: "/Users/demo/Library/Caches/test.uninstall.progress"),
        kind: .caches, size: 0, isSizeKnown: false),
      AppLeftover(
        url: URL(
          fileURLWithPath: "/Users/demo/Library/Group Containers/group.test.uninstall.shared"),
        kind: .containers, size: 0, requiresReview: true, isSizeKnown: false),
    ]
    model.uninstaller.showPreview(
      app: app, items: [], applicationRemoved: false, scanStage: .identity)
    let window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 700),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = NSHostingView(rootView: UninstallInspectorTestHost(model: model))
    defer { window.close() }
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(300))
    let sheet = try #require(window.sheets.first)
    for stage in [
      AppUninstallScanStage.identity, .installations, .leftovers, .sizes,
    ] {
      model.uninstaller.showPreview(
        app: app, items: stage == .sizes ? items : [], applicationRemoved: false, scanStage: stage)
      try await Task.sleep(for: .milliseconds(100))
      #expect(abs(sheet.frame.height - 560) < 1)
      #expect(abs(sheet.frame.width - 560) < 1)
      model.uninstaller.requestUninstall()
      #expect(!model.uninstaller.canUninstall && model.uninstaller.pendingUninstall == nil)
      if let output = ProcessInfo.processInfo.environment["XSTATS_UNINSTALLER_PREVIEW_DIRECTORY"] {
        let content = try #require(sheet.contentView)
        let image = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: image)
        let data = try #require(image.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("stage-\(stage).png"))
      }
    }
  }

  @Test(arguments: [false, true])
  func completedInspectorDismissesButFailuresAndRemainingItemsStay(longName: Bool) async throws {
    let suite = "UninstallerPresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      magpieClient: UnavailableMagpieClient())
    defer { model.uninstaller.setEnabled(false) }
    let app = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/Uninstall-Layout-Demo.app"),
      name: longName ? String(repeating: "Long Application اسم التطبيق ", count: 6) : "Demo",
      bundleIdentifier: "test.uninstall.layout", version: nil, teamIdentifier: nil)
    let cache = AppLeftover(
      url: URL(fileURLWithPath: "/tmp/uninstall-layout-demo-cache"), kind: .caches,
      size: 15_100_000)
    let support = AppLeftover(
      url: URL(fileURLWithPath: "/tmp/uninstall-layout-demo-support"), kind: .support,
      size: 1_000)
    // 只注入演示残留和回收结果，不扫描、删除文件或改动程序坞。
    model.uninstaller.showPreview(app: app, items: [cache, support], applicationRemoved: true)
    let host = NSHostingView(rootView: UninstallInspectorTestHost(model: model))
    let window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 700),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    defer { window.close() }
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(300))
    let sheet = try #require(window.sheets.first)
    #expect(abs(sheet.frame.height - 560) < 1)

    model.uninstaller.finishUninstall(app, items: [cache], moved: [:], errorMessage: "denied")
    try await Task.sleep(for: .milliseconds(300))
    #expect(abs(sheet.frame.height - 560) < 1)

    model.uninstaller.finishUninstall(
      app, items: [cache, support],
      moved: [cache.url: URL(fileURLWithPath: "/tmp/uninstall-layout-demo-trash")],
      errorMessage: nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(window.sheets.count == 1)
    #expect(model.uninstaller.selected == app)
    #expect(abs(sheet.frame.height - 560) < 1)

    model.uninstaller.finishUninstall(
      app, items: [support],
      moved: [support.url: URL(fileURLWithPath: "/tmp/uninstall-layout-demo-support-trash")],
      errorMessage: nil)
    for _ in 0..<40 where !window.sheets.isEmpty {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(window.sheets.isEmpty)
    #expect(model.uninstaller.selected == nil)
  }

  @Test func successFeedbackExpiresAndDoesNotReplayWhenWindowReopens() async throws {
    let suite = "UninstallerPresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      magpieClient: UnavailableMagpieClient())
    model.isMainWindowVisible = true
    model.appManagement.showPreview(apps: [], metadata: [:], sizes: [:], packages: [])
    defer {
      model.appManagement.setVisible(false)
      model.uninstaller.setEnabled(false)
    }
    let app = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/Uninstall-Feedback-Demo.app"), name: "Demo",
      bundleIdentifier: "test.uninstall.feedback", version: nil, teamIdentifier: nil)
    let host = NSHostingView(
      rootView: AppManagementPage().environment(model).environment(\.isSnapshot, true))
    let window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 700),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(100))
    model.appManagement.showUninstallCompletion(for: app)
    try #require(model.appManagement.completion != nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.appManagement.completion != nil)
    let deadline = ContinuousClock.now + .seconds(5)
    while model.appManagement.completion != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(model.appManagement.completion == nil)

    model.appManagement.showUninstallCompletion(for: app)
    model.isMainWindowVisible = false
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.appManagement.completion == nil)
    model.isMainWindowVisible = true
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.appManagement.completion == nil)
  }
}

private struct UninstallInspectorTestHost: View {
  let model: AppModel
  @State private var isPresented = true

  var body: some View {
    Color.clear.frame(width: 800, height: 700)
      .sheet(isPresented: $isPresented, onDismiss: { model.uninstaller.select(nil) }) {
        AppUninstallInspector().environment(model).environment(\.isSnapshot, true)
      }
  }
}
