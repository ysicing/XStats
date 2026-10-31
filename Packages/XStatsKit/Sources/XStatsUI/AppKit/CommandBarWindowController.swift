// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization

/// 原生文本系统负责输入法与编辑快捷键，面板只在显示期间持有索引和控件。
@MainActor
final class CommandBarWindowController: NSObject, NSWindowDelegate, NSSearchFieldDelegate,
  NSTableViewDataSource, NSTableViewDelegate
{
  private(set) var panel: NSPanel?
  private var searchField: NSSearchField?
  private var table: NSTableView?
  private var scroll: NSScrollView?
  private var emptyLabel: NSTextField?
  private var search: CommandBarSearch?
  private var results: [AppCommand] = []
  var onSelect: (AppCommand) -> Void = { _ in }
  var isVisible: Bool { panel?.isVisible == true }

  func show(commands: [AppCommand], language: AppLanguage = L10n.language) {
    if let panel {
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(searchField)
      return
    }
    search = CommandBarSearch(commands: commands)
    results = commands
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
      styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    self.panel = panel
    panel.title = L10n.translate("命令栏", language: language)
    panel.identifier = NSUserInterfaceItemIdentifier("XStatsCommandBar")
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.delegate = self

    let background = NSVisualEffectView()
    background.material = .popover
    background.state = .active
    panel.contentView = background
    let direction: NSUserInterfaceLayoutDirection =
      language.resolved.isRightToLeft ? .rightToLeft : .leftToRight
    background.userInterfaceLayoutDirection = direction

    let field = NSSearchField()
    field.placeholderString = L10n.translate("搜索功能与操作", language: language)
    field.setAccessibilityLabel(field.placeholderString)
    field.font = .systemFont(ofSize: 20)
    field.controlSize = .large
    field.maximumRecents = 0
    field.recentsAutosaveName = nil
    field.searchMenuTemplate = nil
    field.sendsSearchStringImmediately = true
    field.userInterfaceLayoutDirection = direction
    field.delegate = self
    searchField = field

    let table = NSTableView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 36
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.backgroundColor = .clear
    table.style = .fullWidth
    table.allowsEmptySelection = false
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.userInterfaceLayoutDirection = direction
    table.setAccessibilityLabel(panel.title)
    table.delegate = self
    table.dataSource = self
    table.target = self
    table.action = #selector(executeSelection)
    self.table = table

    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    self.scroll = scroll
    let empty = NSTextField(
      wrappingLabelWithString: L10n.translate("没有匹配的项目", language: language))
    empty.textColor = .secondaryLabelColor
    empty.alignment = .center
    empty.isHidden = !results.isEmpty
    empty.userInterfaceLayoutDirection = direction
    emptyLabel = empty

    for view in [field, scroll, empty] {
      view.translatesAutoresizingMaskIntoConstraints = false
      background.addSubview(view)
    }
    NSLayoutConstraint.activate([
      field.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
      field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
      field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
      field.heightAnchor.constraint(equalToConstant: 40),
      scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
      scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
      scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
      scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
      empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
      empty.leadingAnchor.constraint(equalTo: field.leadingAnchor),
      empty.trailingAnchor.constraint(equalTo: field.trailingAnchor),
    ])
    reloadResults()
    // 只在唤出时定位，不监听屏幕或窗口尺寸变化。
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
      ?? NSScreen.main
    {
      let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
      let size = NSSize(
        width: min(panel.frame.width, available.width),
        height: min(panel.frame.height, available.height))
      panel.setFrame(
        NSRect(
          x: available.midX - size.width / 2, y: available.midY - size.height / 2,
          width: size.width, height: size.height), display: false)
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(field)
  }

  func dismiss() {
    guard let panel else { return }
    self.panel = nil
    panel.delegate = nil
    panel.orderOut(nil)
    panel.close()
    panel.contentView = nil
    searchField = nil
    table = nil
    scroll = nil
    emptyLabel = nil
    search = nil
    results = []
  }

  func windowDidResignKey(_ notification: Notification) { dismiss() }
  func windowWillClose(_ notification: Notification) { dismiss() }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = searchField, let search else { return }
    results = search.results(for: field.stringValue)
    reloadResults()
  }

  private func reloadResults() {
    table?.reloadData()
    emptyLabel?.isHidden = !results.isEmpty
    scroll?.isHidden = results.isEmpty
    if !results.isEmpty {
      table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      table?.scrollRowToVisible(0)
    }
  }

  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    // 组词期间上下键、回车和 Esc 属于输入法，不得触发导航或执行。
    guard !textView.hasMarkedText() else { return false }
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)):
      moveSelection(by: 1)
    case #selector(NSResponder.moveUp(_:)):
      moveSelection(by: -1)
    case #selector(NSResponder.insertNewline(_:)):
      executeSelection()
    case #selector(NSResponder.cancelOperation(_:)):
      dismiss()
    default: return false
    }
    return true
  }

  private func moveSelection(by offset: Int) {
    guard let table, !results.isEmpty else { return }
    let row = min(max(table.selectedRow + offset, 0), results.count - 1)
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    table.scrollRowToVisible(row)
  }

  @objc private func executeSelection() {
    guard let row = table?.selectedRow, results.indices.contains(row) else { return }
    let command = results[row]
    dismiss()
    onSelect(command)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { results.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard results.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("command")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
      ?? makeCell(identifier: identifier)
    let command = results[row]
    cell.textField?.stringValue = command.title
    cell.imageView?.image = NSImage(
      systemSymbolName: command.symbol, accessibilityDescription: nil)
    return cell
  }

  private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let image = NSImageView()
    image.contentTintColor = .secondaryLabelColor
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 14)
    label.lineBreakMode = .byTruncatingTail
    cell.userInterfaceLayoutDirection = table?.userInterfaceLayoutDirection ?? .leftToRight
    label.userInterfaceLayoutDirection = cell.userInterfaceLayoutDirection
    label.alignment = .natural
    for view in [image, label] {
      view.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(view)
    }
    cell.imageView = image
    cell.textField = label
    NSLayoutConstraint.activate([
      image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: 18),
      image.heightAnchor.constraint(equalToConstant: 18),
      label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
}
