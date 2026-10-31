// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Testing
@testable import XStatsUI

@MainActor
struct CommandBarWindowTests {
  private let commands = [
    AppCommand(
      id: "network", title: "Network", symbol: "network", keywords: "网络",
      action: .route(.open(.network))),
    AppCommand(
      id: "speedTest", title: "Speed test", symbol: "speedometer", keywords: "测速",
      action: .route(.speedTest)),
  ]

  @Test func keyboardSelectionClosesBeforeDispatchAndEmptyResultsDoNotExecute() throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController()
    defer { controller.dismiss() }
    var selected: AppCommand.Action?
    controller.onSelect = { command in
      #expect(!controller.isVisible)
      selected = command.action
    }
    // 测试回调只在当前作用域存活，结束前撤销以免测试自身保留面板。
    defer { controller.onSelect = { _ in } }
    controller.show(commands: commands)
    let panel = try #require(controller.panel)
    try sendKey("\u{F701}", code: 125, to: panel)
    try sendKey("\r", code: 36, to: panel)
    #expect(selected == .route(.speedTest))
    #expect(controller.panel == nil)

    selected = nil
    controller.show(commands: commands)
    let emptyField = try #require(descendant(NSSearchField.self, in: controller.panel?.contentView))
    emptyField.stringValue = "not a command"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let emptyEditor = try #require(emptyField.currentEditor() as? NSTextView)
    _ = controller.control(
      emptyField, textView: emptyEditor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(selected == nil)
    #expect(controller.isVisible)
  }

  @Test func escapeAndStandardCloseReleaseThePanelWithTableFocus() throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController()
    defer { controller.dismiss() }
    controller.show(commands: commands)
    let panel = try #require(controller.panel)
    let table = try #require(descendant(NSTableView.self, in: panel.contentView))
    panel.makeFirstResponder(table)
    try sendKey("\u{1B}", code: 53, to: panel)
    #expect(controller.panel == nil)
    controller.show(commands: commands)
    controller.panel?.performClose(nil)
    #expect(controller.panel == nil)
  }

  @Test func compositionKeepsNavigationAndEscapeInsideTheInputMethod() throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController()
    defer { controller.dismiss() }
    controller.show(commands: commands)
    let field = try #require(descendant(NSSearchField.self, in: controller.panel?.contentView))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.setMarkedText(
      "wang", selectedRange: NSRange(location: 4, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    for selector in [
      #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)),
      #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
    ] {
      #expect(!controller.control(field, textView: editor, doCommandBy: selector))
    }
    #expect(controller.isVisible)
    editor.unmarkText()
    #expect(
      controller.control(
        field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(controller.panel == nil)
  }

  @Test func repeatedOpeningReusesVisiblePanelAndClosingReleasesItsContent() throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController()
    for _ in 0..<20 {
      weak var releasedContent: NSView?
      weak var releasedPanel: NSPanel?
      autoreleasepool {
        controller.show(commands: commands)
        releasedContent = controller.panel?.contentView
        releasedPanel = controller.panel
        controller.show(commands: commands)
        #expect(controller.panel === releasedPanel)
        controller.dismiss()
        #expect(controller.panel == nil)
      }
      #expect(releasedContent == nil)
      #expect(releasedPanel == nil)
    }
    if let directory = ProcessInfo.processInfo.environment["XSTATS_COMMAND_BAR_PREVIEW_DIR"] {
      controller.show(commands: AppCommand.catalog(supportsFans: true))
      let content = try #require(controller.panel?.contentView)
      content.layoutSubtreeIfNeeded()
      let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("catalog.png"))
      controller.dismiss()
    }
    controller.show(commands: commands)
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(controller.panel == nil)
  }

  private func sendKey(_ characters: String, code: UInt16, to panel: NSPanel) throws {
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code))
    panel.sendEvent(event)
  }

  @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
  func nativePanelFitsTranslatedLabelsAndReadingDirection(language: AppLanguage) throws {
    _ = NSApplication.shared
    let controller = CommandBarWindowController()
    defer { controller.dismiss() }
    let title = L10n.translate("停止防休眠", language: language)
    controller.show(
      commands: [
        AppCommand(
          id: "stop", title: title, symbol: "moon", keywords: "",
          action: .route(.keepAwake(.stop)))
      ], language: language)
    let panel = try #require(controller.panel)
    let content = try #require(panel.contentView)
    content.layoutSubtreeIfNeeded()
    let field = try #require(descendant(NSSearchField.self, in: content))
    #expect(field.frame.width > 400)
    #expect(field.maximumRecents == 0 && field.recentsAutosaveName == nil)
    #expect(
      field.userInterfaceLayoutDirection == (language.isRightToLeft ? .rightToLeft : .leftToRight))
    let table = try #require(descendant(NSTableView.self, in: content))
    let cell = try #require(
      table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
    cell.layoutSubtreeIfNeeded()
    let label = try #require(cell.textField)
    let image = try #require(cell.imageView)
    #expect(label.stringValue == title)
    #expect(label.frame.width >= label.intrinsicContentSize.width)
    #expect(
      language.isRightToLeft
        ? label.frame.midX < image.frame.midX : label.frame.midX > image.frame.midX)
    if let directory = ProcessInfo.processInfo.environment["XSTATS_COMMAND_BAR_PREVIEW_DIR"] {
      let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("\(language.rawValue).png"))
    }
  }

  private func descendant<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
    guard let view else { return nil }
    if let match = view as? T { return match }
    for child in view.subviews {
      if let match = descendant(type, in: child) { return match }
    }
    return nil
  }
}
