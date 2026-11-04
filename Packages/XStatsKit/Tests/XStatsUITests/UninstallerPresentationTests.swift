// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Localization
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct UninstallerPresentationTests {
  @Test(arguments: [AppLanguage.chinese, .english, .german, .arabic], [false, true])
  func homebrewVerificationWarningFitsLongTextAndRTL(language: AppLanguage, dark: Bool) throws {
    _ = NSApplication.shared
    let text = L10n.translate(
      "“Example Developer Tool”的命令已完成，暂时无法核实结果，请刷新后检查", language: language)
    let host = NSHostingView(
      rootView: AppManagementCompletionBanner(text: text, isVerified: false)
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.locale, L10n.locale(for: language))
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(16)
        .frame(width: 340)
        .background(DS.Palette.background))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = host.fittingSize
    #expect(abs(size.width - 340) < 1 && size.height > 60 && size.height < 240)
    if let output = ProcessInfo.processInfo.environment["XSTATS_UNINSTALLER_PREVIEW_DIRECTORY"] {
      host.frame.size = size
      host.layoutSubtreeIfNeeded()
      let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: image)
      let data = try #require(image.representation(using: .png, properties: [:]))
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(
        to: directory.appendingPathComponent(
          "homebrew-verification-\(language.languageCode)-\(dark ? "dark" : "light").png"))
    }
  }

  @Test func permissionFailureKeepsInspectorAndFinderRecoveryVisible() async throws {
    let suite = "UninstallerPermissionPresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      magpieClient: UnavailableMagpieClient())
    defer { model.uninstaller.setEnabled(false) }
    let app = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/Epson Software/Epson Scan 2 Utility.app"),
      name: "Epson Scan 2 Utility", bundleIdentifier: "com.epson.Epson-Scan-2-Utility",
      version: "6.7.84", teamIdentifier: nil)
    let body = AppLeftover(url: app.url, kind: .application, size: 52_800_000)
    model.uninstaller.showPreview(app: app, items: [body], applicationRemoved: false)
    model.uninstaller.finishUninstall(
      app, items: [body], moved: [:],
      error: NSError(
        domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey: "你没有将文件“Epson Scan 2 Utility”移入废纸篓的权限。"
        ]))
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
    #expect(abs(sheet.frame.height - 560) < 1)
    #expect(model.uninstaller.selected == app)
    #expect(model.uninstaller.permissionRecoveryURL == app.url)
    #expect(model.uninstaller.outcome?.isError == true)
    if let output = ProcessInfo.processInfo.environment["XSTATS_UNINSTALLER_PREVIEW_DIRECTORY"] {
      let content = try #require(sheet.contentView)
      let image = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: image)
      let data = try #require(image.representation(using: .png, properties: [:]))
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent("permission-inspector-zh-Hans.png"))
    }
  }

  @Test(arguments: [AppLanguage.chinese, .german, .arabic], [false, true])
  func permissionRecoveryFitsLongSystemErrorsAndRTL(language: AppLanguage, dark: Bool) throws {
    _ = NSApplication.shared
    let app = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/Permission Demo.app"), name: "Permission Demo",
      bundleIdentifier: "test.uninstall.permissions", version: nil, teamIdentifier: nil)
    let body = AppLeftover(url: app.url, kind: .application, size: 52_800_000)
    let controller = UninstallerController(currentBundleIdentifier: nil)
    defer { controller.setEnabled(false) }
    controller.showPreview(app: app, items: [body], applicationRemoved: false)
    let description = L10n.translate(
      "请在访达中移到废纸篓，按提示输入管理员密码。",
      language: language)
    controller.finishUninstall(
      app, items: [body], moved: [:],
      error: NSError(
        domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue,
        userInfo: [NSLocalizedDescriptionKey: description]))
    let host = NSHostingView(
      rootView: UninstallOutcomeBanner(uninstaller: controller, language: language)
        .environment(\.isSnapshot, true)
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.locale, L10n.locale(for: language))
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(16)
        .background(DS.Palette.background)
        .frame(width: 528))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = host.fittingSize
    #expect(abs(size.width - 528) < 1 && size.height > 60 && size.height < 400)
    #expect(controller.permissionRecoveryURL == app.url)
    if let output = ProcessInfo.processInfo.environment["XSTATS_UNINSTALLER_PREVIEW_DIRECTORY"] {
      host.frame.size = size
      host.layoutSubtreeIfNeeded()
      let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: image)
      let data = try #require(image.representation(using: .png, properties: [:]))
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(
        to: directory.appendingPathComponent(
          "permission-\(language.languageCode)-\(dark ? "dark" : "light").png"))
    }
  }

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

    model.uninstaller.finishUninstall(
      app, items: [cache], moved: [:], error: CocoaError(.fileWriteNoPermission) as NSError)
    try await Task.sleep(for: .milliseconds(300))
    #expect(abs(sheet.frame.height - 560) < 1)

    model.uninstaller.finishUninstall(
      app, items: [cache, support],
      moved: [cache.url: URL(fileURLWithPath: "/tmp/uninstall-layout-demo-trash")],
      error: nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(window.sheets.count == 1)
    #expect(model.uninstaller.selected == app)
    #expect(abs(sheet.frame.height - 560) < 1)

    model.uninstaller.finishUninstall(
      app, items: [support],
      moved: [support.url: URL(fileURLWithPath: "/tmp/uninstall-layout-demo-support-trash")],
      error: nil)
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
        AppUninstallInspector()
          .environment(model)
          .environment(\.isSnapshot, true)
          .background(DS.Palette.background)
          .environment(\.colorScheme, .light)
      }
  }
}
