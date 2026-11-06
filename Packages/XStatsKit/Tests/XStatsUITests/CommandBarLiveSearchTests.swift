// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin
import Localization
import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct CommandBarLiveSearchTests {
  @Test func parsingKeepsArgumentsLiteralAndBoundsInput() {
    #expect(CommandBarLiveRequest("OPEN 季度 报告") == .files("季度 报告"))
    #expect(CommandBarLiveRequest("FIND 季度 报告") == .revealFiles("季度 报告"))
    #expect(CommandBarLiveRequest("kill") == .processes(""))
    #expect(CommandBarLiveRequest("kill :3000") == .processes(":3000"))
    #expect(CommandBarLiveRequest("killer") == nil)
    #expect(CommandBarLiveRequest("open " + String(repeating: "x", count: 257)) == nil)
    #expect(CommandBarLiveRequest("open a; rm -rf /") == .files("a; rm -rf /"))
  }

  @Test func chineseFilenamesMatchFullPinyinAndInitials() throws {
    let command = try #require(
      CommandBarFileSearch.command(
        path: "/Users/demo/Documents/年度报告.key", name: "年度报告.key", contentType: nil))
    let index = CommandBarSearch(commands: [command], supportsParameterQueries: false)
    for text in ["baogao", "BG", "niandu baogao", "ndbg"] {
      #expect(CommandBarFileSearch.supportsPinyin(text))
      #expect(index.results(for: text).map(\.id) == [command.id])
    }
    #expect(index.results(for: "年度 bg").map(\.id) == [command.id])
    #expect(CommandBarFileSearch.supportsPinyin("年度 bg"))
    #expect(index.results(for: "baobiao").isEmpty)
    #expect(!CommandBarFileSearch.supportsPinyin("[*]"))
    #expect(!CommandBarFileSearch.supportsPinyin("报告"))
  }

  @Test func findReturnAndOpenActionHaveDistinctRoutesAndDiscardStaleMenus() throws {
    _ = NSApplication.shared
    let url = URL(fileURLWithPath: "/Users/demo/Documents/报告.key")
    let command = AppCommand(
      id: "file.fixture", title: "报告.key", symbol: "doc", keywords: "",
      action: .revealFile(url))
    #expect(command.fileURL == url)
    #expect(command.usageID == "search.files")
    let controller = CommandBarWindowController()
    defer {
      controller.onSelect = { _ in }
      controller.dismiss()
    }
    var actions: [AppCommand.Action] = []
    controller.onSelect = { actions.append($0.action) }
    controller.show(commands: [command])
    let panel = try #require(controller.panel)
    let field = try #require(descendant(NSSearchField.self, in: panel.contentView))
    let editor = try #require(field.currentEditor() as? NSTextView)
    let menu = try #require(controller.resultActionsMenu())
    let open = try #require(menu.items.first { $0.tag == 0 })
    #expect(menu.items.first { $0.tag == 4 }?.keyEquivalent == "y")
    #expect(menu.items.first { $0.tag == 5 }?.submenu?.items.isEmpty == false)
    #expect(menu.items.contains { $0.tag == 6 })
    #expect(
      controller.control(
        field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(actions == [.revealFile(url)])
    controller.show(commands: [command])
    NSApp.sendAction(try #require(open.action), to: open.target, from: open)
    #expect(actions.count == 1)
    #expect(controller.isVisible)
    let current = try #require(controller.resultActionsMenu()?.items.first { $0.tag == 0 })
    NSApp.sendAction(try #require(current.action), to: current.target, from: current)
    #expect(actions == [.revealFile(url), .openFile(url)])
    #expect(!controller.isVisible)
  }

  @Test func quickLookShortcutTogglesAndDismissalReleasesPreview() throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("xstats-preview-\(UUID().uuidString).txt")
    try Data("Quick Look fixture".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let command = AppCommand(
      id: "file.preview", title: url.lastPathComponent, symbol: "doc",
      keywords: "", action: .openFile(url))
    let controller = CommandBarWindowController()
    defer { controller.dismiss() }
    controller.show(commands: [command])
    let panel = try #require(controller.panel)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command],
        timestamp: 0, windowNumber: panel.windowNumber, context: nil,
        characters: "y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16))
    #expect(panel.performKeyEquivalent(with: event))
    let first = try #require(controller.previewPanel)
    #expect(controller.panel === panel)
    controller.windowDidResignKey(
      Notification(name: NSWindow.didResignKeyNotification, object: panel))
    #expect(controller.panel === panel)
    #expect(first.performKeyEquivalent(with: event))
    #expect(controller.previewPanel == nil)
    #expect(first.contentView == nil)
    #expect(panel.performKeyEquivalent(with: event))
    controller.previewPanel?.cancelOperation(nil)
    #expect(controller.previewPanel == nil)
    #expect(controller.panel === panel)
    #expect(controller.togglePreview())
    let last = try #require(controller.previewPanel)
    controller.dismiss()
    #expect(controller.previewPanel == nil)
    #expect(last.contentView == nil)
  }

  @Test func previewFocusCanReturnToSearchAndLeavingBothPanelsDismisses() async throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController()
    defer { controller.dismiss() }
    let command = AppCommand(
      id: "file.focus", title: "Preview", symbol: "doc", keywords: "",
      action: .openFile(URL(fileURLWithPath: "/tmp", isDirectory: true)))
    controller.show(commands: [command])
    let panel = try #require(controller.panel)
    #expect(controller.togglePreview())
    let preview = try #require(controller.previewPanel)
    panel.makeKeyAndOrderFront(nil)
    controller.windowDidResignKey(
      Notification(name: NSWindow.didResignKeyNotification, object: preview))
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.panel === panel)
    #expect(controller.previewPanel === preview)
    let other = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    other.makeKeyAndOrderFront(nil)
    controller.windowDidResignKey(
      Notification(name: NSWindow.didResignKeyNotification, object: panel))
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.panel == nil)
    #expect(controller.previewPanel == nil)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_LIVE_FILE_SEARCH"] == "1"))
  func spotlightFindsChineseFixtureThroughPinyin() async throws {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Downloads/XStats-Search-Test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("年度报告.txt")
    try Data("XStats file search test fixture".utf8).write(to: url)
    let search = CommandBarFileSearch()
    defer {
      search.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    var found = false
    for _ in 0..<3 {
      search.stop()
      search.start("niandubaogao") { commands in
        found = commands.contains { $0.fileURL == url }
      }
      for _ in 0..<70 {
        if found { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      if found { break }
    }
    #expect(found)
    found = false
    search.start("ndbg") { commands in found = commands.contains { $0.fileURL == url } }
    for _ in 0..<70 {
      if found { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(found)
  }

  @Test func filePredicateDoesNotInterpretQuerySyntax() throws {
    #expect(CommandBarFileSearch.predicate("") == nil)
    #expect(CommandBarFileSearch.predicate("a") == nil)
    #expect(CommandBarFileSearch.predicate("报告") != nil)
    let predicate = try #require(CommandBarFileSearch.predicate("report [*]"))
    #expect(predicate.evaluate(with: [NSMetadataItemFSNameKey: "Report [*].pdf"]))
    #expect(!predicate.evaluate(with: [NSMetadataItemFSNameKey: "Report other.pdf"]))
  }

  @Test func fileRowsCarryTypeAndPathWithoutPersistingThePath() throws {
    let command = try #require(
      CommandBarFileSearch.command(
        path: "/Users/demo/Documents/报告.key", name: "报告.key", contentType: nil))
    #expect(command.title == "报告.key")
    #expect(command.badge == "KEY")
    #expect(command.subtitle == "/Users/demo/Documents")
    #expect(command.usageID == "search.files")
    let folder = try #require(
      CommandBarFileSearch.command(
        path: "/Users/demo/Documents/报告", name: "报告", contentType: "public.folder"))
    #expect(folder.badge == "文件夹")
    guard case .openFile(let url) = folder.action else {
      Issue.record("Missing file action")
      return
    }
    #expect(url.hasDirectoryPath)
    for path in [
      "/Users/demo/.hidden/file", "/Users/demo/node_modules/file",
      "/Applications/Demo.app/Contents/file",
    ] {
      #expect(CommandBarFileSearch.command(path: path, name: "file", contentType: nil) == nil)
    }
  }

  @Test func processFilterSeparatesPIDAndListeningPort() {
    let target = fixture()
    #expect(target.matches(""))
    #expect(target.matches("NODE"))
    #expect(target.matches("4321"))
    #expect(!target.matches("432"))
    #expect(target.matches(":30"))
    #expect(target.matches("node :3000"))
    #expect(!target.matches(":4321"))
    #expect(!target.matches("python"))
    #expect(target.command().usageID == "search.processes")
  }

  @Test func terminationRejectsReusedPIDOtherUsersSelfAndProtectedProcesses() {
    let target = fixture()
    #expect(CommandBarProcessActions.canTerminate(target, current: target.identity))
    #expect(!CommandBarProcessActions.canTerminate(target, current: nil))
    let replacement = CommandBarProcessTarget.Identity(
      seconds: 200, microseconds: 0, uid: getuid(), parent: 1)
    #expect(!CommandBarProcessActions.canTerminate(target, current: replacement))
    for blocked in [
      fixture(pid: getpid()), fixture(pid: 1), fixture(uid: 0), fixture(name: "loginwindow"),
    ] {
      #expect(!CommandBarProcessActions.canTerminate(blocked, current: blocked.identity))
    }
  }

  @Test(arguments: ["open ", "find ", "kill "])
  func choosingSearchEntryKeepsPanelOpenAndCompletesInput(query: String) throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController(processLoader: { _ in [] })
    defer { controller.dismiss() }
    let command = AppCommand(
      id: "search", title: "Search", symbol: "magnifyingglass", keywords: "",
      action: .completeQuery(query))
    controller.onSelect = { _ in Issue.record("Search entry must keep input inside the panel") }
    controller.show(commands: [command])
    let panel = try #require(controller.panel)
    let field = try #require(descendant(NSSearchField.self, in: panel.contentView))
    let editor = try #require(field.currentEditor() as? NSTextView)
    #expect(
      controller.control(
        field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(controller.panel === panel)
    #expect(field.stringValue == query)
    #expect(field.currentEditor() != nil)
  }

  @Test func processModeLoadsOnceFiltersInMemoryAndDispatchesAfterDismissal() async throws {
    _ = NSApplication.shared
    let probe = SnapshotProbe(targets: [fixture()])
    let controller = CommandBarWindowController(processLoader: { _ in probe.load() })
    defer {
      controller.onSelect = { _ in }
      controller.dismiss()
    }
    controller.show(commands: [])
    let field = try #require(descendant(NSSearchField.self, in: controller.panel?.contentView))
    let table = try #require(descendant(NSTableView.self, in: controller.panel?.contentView))
    search("kill", field: field, controller: controller)
    for _ in 0..<100 where table.numberOfRows == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(table.numberOfRows == 1)
    search("kill python", field: field, controller: controller)
    #expect(table.numberOfRows == 0)
    search("kill :3000", field: field, controller: controller)
    #expect(table.numberOfRows == 1)
    #expect(probe.count == 1)
    let cell = try #require(
      table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
    #expect(cell.textField?.stringValue == "node")
    #expect(cell.imageView?.image != nil)
    var selected: AppCommand?
    controller.onSelect = {
      #expect(controller.panel == nil)
      selected = $0
    }
    let editor = try #require(field.currentEditor() as? NSTextView)
    _ = controller.control(
      field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(selected?.action == .terminateProcess(fixture()))
    #expect(controller.panel == nil)
  }

  @Test func lateProcessSnapshotCannotOverwriteAnotherModeOrSession() async throws {
    _ = NSApplication.shared
    let probe = SnapshotProbe(targets: [fixture()], waits: true)
    let controller = CommandBarWindowController(processLoader: { _ in probe.load() })
    defer {
      probe.release()
      controller.dismiss()
    }
    let command = AppCommand(
      id: "test", title: "Test", symbol: "app", keywords: "", action: .checkForUpdates)
    controller.show(commands: [command])
    let field = try #require(descendant(NSSearchField.self, in: controller.panel?.contentView))
    search("kill", field: field, controller: controller)
    for _ in 0..<100 where probe.count == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    controller.dismiss()
    controller.show(commands: [command])
    probe.release()
    try await Task.sleep(for: .milliseconds(80))
    let table = try #require(descendant(NSTableView.self, in: controller.panel?.contentView))
    #expect(table.numberOfRows == 1)
    let cell = try #require(
      table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
    #expect(cell.textField?.stringValue == "Test")
  }

  @Test func fileModeDebouncesAndClosingStopsQuery() async throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController()
    defer { controller.dismiss() }
    controller.show(commands: [])
    let field = try #require(descendant(NSSearchField.self, in: controller.panel?.contentView))
    search("open xstats-query-test-unlikely", field: field, controller: controller)
    #expect(!controller.fileSearch.isRunning)
    search("open", field: field, controller: controller)
    try await Task.sleep(for: .milliseconds(210))
    #expect(!controller.fileSearch.isRunning)
    search("open xstats-query-test-unlikely", field: field, controller: controller)
    controller.dismiss()
    try await Task.sleep(for: .milliseconds(210))
    #expect(!controller.fileSearch.isRunning)
    #expect(controller.panel == nil)
  }

  @Test(arguments: ["xstats-query-lifecycle-probe", "xstats query-lifecycle-probe"])
  func stoppedMetadataQueryCannotDeliverResults(text: String) async throws {
    let search = CommandBarFileSearch()
    var deliveries = 0
    search.start(text) { _ in deliveries += 1 }
    #expect(search.isRunning)
    search.stop()
    let stoppedCount = deliveries
    try await Task.sleep(for: .milliseconds(100))
    #expect(!search.isRunning)
    #expect(deliveries == stoppedCount)
    search.stop()
  }

  @Test func liveReadChecksWhenRequested() async throws {
    guard let directory = ProcessInfo.processInfo.environment["XSTATS_COMMAND_BAR_PREVIEW_DIR"]
    else { return }
    let started = Date()
    let excluded = Set(
      NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular
      }.map(\.processIdentifier))
    let targets = try await Task.detached {
      try CommandBarProcessTarget.snapshot(excluding: excluded)
    }.value
    #expect(
      targets.allSatisfy {
        $0.identity.uid == getuid() && $0.process.pid != getpid()
          && !excluded.contains($0.process.pid)
      })
    let data = try JSONSerialization.data(
      withJSONObject: [
        "elapsedSeconds": Date().timeIntervalSince(started),
        "targetCount": targets.count,
      ], options: [.prettyPrinted, .sortedKeys])
    try data.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("process-sample.json"))
  }

  @Test(arguments: [AppLanguage.chinese, .english, .german, .arabic])
  func nativeResultRowsFitLongNamesAndTranslatedActions(language: AppLanguage) throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController()
    defer { controller.dismiss() }
    let folder = try #require(
      CommandBarFileSearch.command(
        path: "/Users/demo/Documents/报告", name: "报告", contentType: "public.folder"))
    let file = try #require(
      CommandBarFileSearch.command(
        path: "/Users/demo/Documents/Work/很长的年度报告文件名与详细版本说明.key",
        name: "很长的年度报告文件名与详细版本说明.key", contentType: nil))
    controller.show(
      commands: [folder, file, fixture().command(language: language)], language: language)
    let panel = try #require(controller.panel)
    let content = try #require(panel.contentView)
    content.layoutSubtreeIfNeeded()
    let table = try #require(descendant(NSTableView.self, in: content))
    #expect(table.rowHeight == 52)
    for row in 0..<3 {
      let cell = try #require(
        table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
      cell.layoutSubtreeIfNeeded()
      let label = try #require(cell.textField)
      let image = try #require(cell.imageView)
      #expect(image.image != nil)
      #expect(cell.bounds.insetBy(dx: -1, dy: -1).contains(cell.convert(label.bounds, from: label)))
      #expect(label.alignment == (language.isRightToLeft ? .right : .left))
    }
    let actions = try #require(
      descendants(NSButton.self, in: content)
        .first { $0.keyEquivalent == "k" })
    #expect(!actions.isHidden)
    #expect(actions.frame.width >= actions.intrinsicContentSize.width)
    if let directory = ProcessInfo.processInfo.environment["XSTATS_COMMAND_BAR_PREVIEW_DIR"] {
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        panel.appearance = NSAppearance(named: appearance)
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent(
            "live-results-\(language.rawValue)-\(appearance.rawValue).png"))
      }
    }
  }

  private func fixture(
    pid: Int32 = 4321, uid: UInt32 = getuid(), name: String = "node"
  ) -> CommandBarProcessTarget {
    var process = ProcessUsage(
      pid: pid, name: name, executablePath: "/usr/local/bin/\(name)",
      appBundlePath: nil, cpu: 0, memory: 312 * 1024 * 1024)
    process.uid = uid
    return CommandBarProcessTarget(
      process: process,
      identity: .init(seconds: 100, microseconds: 0, uid: uid, parent: 1), ports: [3000])
  }

  private func search(
    _ text: String, field: NSSearchField, controller: CommandBarWindowController
  ) {
    field.stringValue = text
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  }

  private func descendant<View: NSView>(_ type: View.Type, in view: NSView?) -> View? {
    guard let view else { return nil }
    if let result = view as? View { return result }
    return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
  }

  private func descendants<View: NSView>(_ type: View.Type, in view: NSView) -> [View] {
    ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
  }
}

private final class SnapshotProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var loads = 0
  private let targets: [CommandBarProcessTarget]
  private let waits: Bool

  init(targets: [CommandBarProcessTarget], waits: Bool = false) {
    self.targets = targets
    self.waits = waits
  }

  var count: Int { lock.withLock { loads } }

  func load() -> [CommandBarProcessTarget] {
    lock.withLock { loads += 1 }
    if waits { _ = semaphore.wait(timeout: .now() + 3) }
    return targets
  }

  func release() { semaphore.signal() }
}
