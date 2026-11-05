// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct CommandBarLauncherTests {
  @Test func applicationScanIsShallowDeduplicatedAndRefreshesAfterRemoval() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let primary = try makeApplication(at: root.appendingPathComponent("工具.app"))
    let utility = try makeApplication(at: root.appendingPathComponent("Utilities/Tool.app"))
    _ = try makeApplication(at: root.appendingPathComponent("Utilities/Deep/Hidden.app"))
    _ = try makeApplication(at: primary.appendingPathComponent("Contents/Helper.app"))
    _ = try makeApplication(at: root.appendingPathComponent(".Hidden.app"))
    try manager.createSymbolicLink(
      at: root.appendingPathComponent("Alias.app"), withDestinationURL: primary)
    let invalid = root.appendingPathComponent("Invalid.app")
    try manager.createDirectory(at: invalid, withIntermediateDirectories: true)
    let commands = try CommandBarApplications.scan(directories: [root, root])
    #expect(commands.count == 2)
    #expect(Set(commands.map(\.id)).count == 2)
    #expect(commands.contains { $0.action == .openApplication(primary.resolvingSymlinksInPath()) })
    #expect(CommandBarSearch(commands: commands).results(for: "gongju").count == 1)
    #expect(try CommandBarApplications.scanResult(directories: [root]).isTruncated == false)
    try manager.removeItem(at: utility)
    #expect(try CommandBarApplications.scan(directories: [root]).count == 1)
  }

  @Test func removingDropsOnlyTheNamedEntryFromSearch() {
    let first = AppCommand(
      id: "application.a", title: "Alpha", symbol: "app", keywords: "",
      action: .openApplication(URL(fileURLWithPath: "/tmp/Alpha.app")))
    let second = AppCommand(
      id: "application.b", title: "Alpha Two", symbol: "app", keywords: "",
      action: .openApplication(URL(fileURLWithPath: "/tmp/AlphaTwo.app")))
    let search = CommandBarSearch(commands: [first, second], supportsParameterQueries: false)
    #expect(search.removing(first.id).results(for: "alpha").map(\.id) == [second.id])
    #expect(search.results(for: "alpha").count == 2)
  }

  @Test func usageIsBoundedPersistentAndDoesNotStoreQueryArguments() throws {
    let suite = "CommandBarLauncherTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let usage = CommandBarUsage(defaults: defaults)
    for index in 0..<20 {
      let command = fixture(id: "command.\(index)")
      usage.record(command)
      usage.toggleFavorite(command.id)
    }
    #expect(usage.recent.count == 10)
    #expect(usage.favorites.count == 8)
    usage.record(fixture(id: "command.19"))
    #expect(usage.recent.count == 10)
    usage.record(
      AppCommand(
        id: "ps.private-query", title: "", symbol: "", keywords: "",
        action: .findProcesses("private-query")))
    #expect(usage.recent.first == "page.processes")
    #expect(!defaults.dictionaryRepresentation().description.contains("private-query"))
    let restored = CommandBarUsage(defaults: defaults)
    #expect(restored.recent == usage.recent && restored.favorites == usage.favorites)
    restored.clearRecent()
    #expect(CommandBarUsage(defaults: defaults).recent.isEmpty)
    #expect(CommandBarUsage(defaults: defaults).favorites.count == 8)
    restored.toggleFavorite("command.0")
    restored.toggleFavorite("command.19")
    #expect(restored.favorites.last == "command.19")
    restored.clearFavorites()
    #expect(CommandBarUsage(defaults: defaults).favorites.isEmpty)
  }

  @Test func favoritesAndRecentsBreakTiesWithoutOutrankingExactTitles() {
    let commands = [
      AppCommand(id: "exact", title: "Tool", symbol: "", keywords: "", action: .checkForUpdates),
      AppCommand(
        id: "prefix", title: "Tool box", symbol: "", keywords: "", action: .checkForUpdates),
      AppCommand(
        id: "keyword", title: "Other", symbol: "", keywords: "tool", action: .checkForUpdates),
    ]
    let search = CommandBarSearch(commands: commands)
    #expect(
      search.results(for: "", favorites: ["keyword"], recent: ["prefix"]).map(\.id)
        == ["keyword", "prefix", "exact"])
    #expect(
      search.results(for: "tool", favorites: ["keyword"], recent: ["prefix"]).map(\.id)
        == ["exact", "prefix", "keyword"])
  }

  @Test func processAndIPCommandsOnlyNavigateAndValidatePIDs() {
    let search = CommandBarSearch(commands: AppCommand.catalog(supportsFans: false))
    #expect(
      search.results(for: "ps Window Server").first?.action == .findProcesses("window server"))
    #expect(search.results(for: "ps 42").first?.action == .findProcesses("42"))
    #expect(search.results(for: "ps 0").isEmpty)
    #expect(search.results(for: "ps 99999999999999").isEmpty)
    #expect(search.results(for: "ip").first?.action == .localIPQuery)
    #expect(CommandBarSearch(commands: []).results(for: "ps 42").isEmpty)
    let target = ProcessNavigationTarget.query("42")
    let process = ProcessUsage(
      pid: 42, name: "WindowServer", executablePath: nil, appBundlePath: nil, cpu: 0, memory: 0)
    #expect(target.matches(process))
    #expect(!ProcessNavigationTarget.query("4").matches(process))
    #expect(ProcessNavigationTarget.query("window").matches(process))
  }

  @Test func localIPNavigationDoesNotEnableNetworkMonitoringOrKeepPortDemand() throws {
    let suite = "CommandBarLauncherTests.navigation.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    let monitoring = settings.enabledMonitoringModules
    var opened: PanelTab?
    model.openMainWindow = { opened = $0 }
    model.portNavigationTarget = 3000
    model.isPortsSheetPresented = true
    model.showLocalIPQuery()
    #expect(model.localIPQueryRequested)
    #expect(model.portNavigationTarget == nil && !model.isPortsSheetPresented)
    #expect(opened == .network && settings.panelTab == .network)
    #expect(settings.enabledMonitoringModules == monitoring)
  }

  @Test func lateApplicationScanCannotRepopulateAClosedOrReopenedPanel() async throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController()
    defer { controller.dismiss() }
    let old = fixture(id: "old")
    let fresh = fixture(id: "fresh")
    controller.show(
      commands: [old],
      applicationLoader: {
        Thread.sleep(forTimeInterval: 0.05)
        return [old]
      })
    controller.dismiss()
    controller.show(commands: [fresh])
    try await Task.sleep(for: .milliseconds(150))
    let table = try #require(descendant(NSTableView.self, in: controller.panel?.contentView))
    #expect(table.numberOfRows == 1)
    let cell = try #require(
      table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
    #expect(cell.textField?.stringValue == "fresh")
  }

  @Test func appIndexCompletionPreservesQueryAndSelection() async throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController()
    defer { controller.dismiss() }
    let base = fixture(id: "test")
    let added = fixture(id: "extra")
    controller.show(commands: [base], applicationLoader: { [added] })
    let field = try #require(descendant(NSSearchField.self, in: controller.panel?.contentView))
    field.stringValue = "test"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    try await Task.sleep(for: .milliseconds(150))
    let table = try #require(descendant(NSTableView.self, in: controller.panel?.contentView))
    #expect(table.numberOfRows == 1)
    #expect(field.stringValue == "test")
    field.stringValue = "extra"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(table.numberOfRows == 1)
    let cell = try #require(
      table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
    #expect(cell.textField?.stringValue == "extra")
  }

  @Test func liveApplicationScanTimingWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["XSTATS_LAUNCHER_SCAN_CHECK"] == "1" else { return }
    let worker = Task.detached {
      let clock = ContinuousClock()
      let start = clock.now
      let applications = try CommandBarApplications.scan()
      let index = CommandBarSearch(commands: applications)
      return (applications.count, index.results(for: "").count, start.duration(to: clock.now))
    }
    let (count, indexed, duration) = try await worker.value
    #expect(count > 0 && count <= 2_000 && indexed == count)
    print("Launcher scan and index: \(count) apps, \(duration)")
  }

  @Test(arguments: [false, true])
  func arrivingFavoritesSelectFirstOnlyBeforeUserNavigation(navigate: Bool) async throws {
    _ = NSApplication.shared
    let suite = "CommandBarLauncherTests.selection.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let usage = CommandBarUsage(defaults: defaults)
    usage.toggleFavorite("favorite")
    let controller = CommandBarWindowController(usage: usage)
    defer { controller.dismiss() }
    let favorite = fixture(id: "favorite")
    controller.show(
      commands: [fixture(id: "first"), fixture(id: "second")],
      applicationLoader: {
        [favorite]
      })
    if navigate {
      let field = try #require(descendant(NSSearchField.self, in: controller.panel?.contentView))
      let editor = try #require(field.currentEditor() as? NSTextView)
      _ = controller.control(
        field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
    }
    try await Task.sleep(for: .milliseconds(150))
    let table = try #require(descendant(NSTableView.self, in: controller.panel?.contentView))
    let cell = try #require(
      table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) as? NSTableCellView)
    #expect(cell.textField?.stringValue == (navigate ? "second" : "favorite"))
  }

  @Test(arguments: [AppLanguage.chinese, .german, .arabic])
  func launcherFooterAndFavoriteSelectionFitNativePanel(language: AppLanguage) throws {
    _ = NSApplication.shared
    let suite = "CommandBarLauncherTests.layout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let usage = CommandBarUsage(defaults: defaults)
    let controller = CommandBarWindowController(usage: usage)
    defer { controller.dismiss() }
    let command = AppCommand(
      id: "test", title: "Safari", symbol: "app", keywords: "",
      action: .openApplication(URL(fileURLWithPath: "/Applications/Safari.app")))
    let examples = [
      command,
      AppCommand(
        id: "localIP", title: L10n.translate("本机 IP 查询", language: language), symbol: "globe",
        keywords: "", action: .localIPQuery),
      AppCommand(
        id: "dnsBenchmark", title: L10n.translate("DNS 测试", language: language),
        symbol: "server.rack",
        keywords: "", action: .dnsBenchmark),
      AppCommand(
        id: "page.processes", title: L10n.translate("进程", language: language),
        symbol: "list.bullet",
        keywords: "", action: .route(.open(.processes))),
    ]
    usage.record(examples[1])
    usage.toggleFavorite("test")
    controller.show(commands: examples, language: language)
    let panel = try #require(controller.panel)
    let content = try #require(panel.contentView)
    content.layoutSubtreeIfNeeded()
    let button = try #require(
      descendants(NSButton.self, in: content).first { $0.keyEquivalent == "d" })
    #expect(button.keyEquivalentModifierMask == .command)
    // 本机 Swift Testing 宿主中 performClick 的跟踪循环会令 async main 提前退出。
    // 直接验证同一个原生 target/action，避免把退出码 0 误认为用例完成。
    let action = try #require(button.action)
    #expect(NSApp.sendAction(action, to: button.target, from: button))
    #expect(usage.favorites.isEmpty)
    #expect(NSApp.sendAction(action, to: button.target, from: button))
    #expect(usage.favorites == ["test"])
    content.layoutSubtreeIfNeeded()
    #expect(button.frame.width >= button.intrinsicContentSize.width)
    #expect(content.bounds.contains(content.convert(button.bounds, from: button)))
    let hint = try #require(
      descendants(NSTextField.self, in: content).first { $0.stringValue.contains("↑↓") })
    #expect(
      !content.convert(hint.bounds, from: hint).intersects(
        content.convert(button.bounds, from: button)))
    if let directory = ProcessInfo.processInfo.environment["XSTATS_COMMAND_BAR_PREVIEW_DIR"] {
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        panel.appearance = NSAppearance(named: appearance)
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent(
            "launcher-\(language.rawValue)-\(appearance.rawValue).png"))
      }
    }
  }

  private func fixture(id: String) -> AppCommand {
    AppCommand(id: id, title: id, symbol: "app", keywords: "", action: .checkForUpdates)
  }

  private func makeApplication(at url: URL) throws -> URL {
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "test.\(UUID())", "CFBundlePackageType": "APPL"],
      format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return url
  }

  private func descendant<View: NSView>(_ type: View.Type, in view: NSView?) -> View? {
    descendants(type, in: view).first
  }

  private func descendants<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
    guard let view else { return [] }
    return (view as? View).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
  }
}
