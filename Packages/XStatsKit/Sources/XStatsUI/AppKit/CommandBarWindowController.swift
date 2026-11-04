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
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 432),
      styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    self.panel = panel
    panel.title = L10n.translate("命令栏", language: language)
    panel.identifier = NSUserInterfaceItemIdentifier("XStatsCommandBar")
    panel.titleVisibility = .visible
    panel.titlebarAppearsTransparent = true
    panel.backgroundColor = .dsBackground
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.delegate = self

    let surface = NSBox()
    surface.boxType = .custom
    surface.borderWidth = 0
    surface.titlePosition = .noTitle
    surface.fillColor = .dsBackground
    surface.contentViewMargins = .zero
    let background = NSView()
    surface.contentView = background
    panel.contentView = surface
    let direction: NSUserInterfaceLayoutDirection =
      language.resolved.isRightToLeft ? .rightToLeft : .leftToRight
    background.userInterfaceLayoutDirection = direction

    let field = NSSearchField()
    field.placeholderString = L10n.translate("搜索功能与操作", language: language)
    field.setAccessibilityLabel(field.placeholderString)
    field.font = .systemFont(ofSize: DS.TextSize.lg.rawValue)
    field.controlSize = .large
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
    field.maximumRecents = 0
    field.recentsAutosaveName = nil
    field.searchMenuTemplate = nil
    field.sendsSearchStringImmediately = true
    field.userInterfaceLayoutDirection = direction
    field.alignment = direction == .rightToLeft ? .right : .left
    field.delegate = self
    searchField = field

    let searchBackground = NSBox()
    searchBackground.boxType = .custom
    searchBackground.borderWidth = 0
    searchBackground.titlePosition = .noTitle
    searchBackground.cornerRadius = DS.Radius.md
    searchBackground.fillColor = NSColor(DS.Palette.surface)

    let searchIcon = NSImageView()
    searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    searchIcon.contentTintColor = NSColor(DS.Palette.textSecondary)
    searchIcon.symbolConfiguration = .init(pointSize: DS.Size.iconInline, weight: .regular)

    let table = NSTableView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = DS.Size.controlHeight + DS.Space.s2
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.backgroundColor = .clear
    table.style = .fullWidth
    table.focusRingType = .none
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

    for view in [searchBackground, searchIcon, field, scroll, empty] {
      view.translatesAutoresizingMaskIntoConstraints = false
      background.addSubview(view)
    }
    NSLayoutConstraint.activate([
      searchBackground.topAnchor.constraint(equalTo: background.topAnchor, constant: 36),
      searchBackground.leadingAnchor.constraint(
        equalTo: background.leadingAnchor, constant: DS.Space.s4),
      searchBackground.trailingAnchor.constraint(
        equalTo: background.trailingAnchor, constant: -DS.Space.s4),
      searchBackground.heightAnchor.constraint(equalToConstant: DS.Space.s12),
      searchIcon.leadingAnchor.constraint(
        equalTo: searchBackground.leadingAnchor, constant: DS.Space.s3),
      searchIcon.centerYAnchor.constraint(equalTo: searchBackground.centerYAnchor),
      searchIcon.widthAnchor.constraint(equalToConstant: DS.Size.iconStandalone),
      searchIcon.heightAnchor.constraint(equalToConstant: DS.Size.iconStandalone),
      field.centerYAnchor.constraint(equalTo: searchBackground.centerYAnchor),
      field.leadingAnchor.constraint(
        equalTo: searchIcon.trailingAnchor, constant: DS.Space.s2),
      field.trailingAnchor.constraint(
        equalTo: searchBackground.trailingAnchor, constant: -DS.Space.s3),
      field.heightAnchor.constraint(equalToConstant: DS.Size.controlHeight),
      scroll.topAnchor.constraint(equalTo: searchBackground.bottomAnchor, constant: DS.Space.s2),
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

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    CommandBarRowView()
  }

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
    image.contentTintColor = NSColor(DS.Palette.textSecondary)
    image.symbolConfiguration = .init(pointSize: DS.Size.iconInline, weight: .regular)
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: DS.TextSize.sm.rawValue, weight: .medium)
    label.textColor = NSColor(DS.Palette.textPrimary)
    label.lineBreakMode = .byTruncatingTail
    cell.userInterfaceLayoutDirection = table?.userInterfaceLayoutDirection ?? .leftToRight
    label.userInterfaceLayoutDirection = cell.userInterfaceLayoutDirection
    label.alignment = cell.userInterfaceLayoutDirection == .rightToLeft ? .right : .left
    for view in [image, label] {
      view.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(view)
    }
    cell.imageView = image
    cell.textField = label
    NSLayoutConstraint.activate([
      image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: DS.Space.s4),
      image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: DS.Size.iconStandalone),
      image.heightAnchor.constraint(equalToConstant: DS.Size.iconStandalone),
      label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: DS.Space.s3),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -DS.Space.s4),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
}

private final class CommandBarRowView: NSTableRowView {
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

  override func drawSelection(in dirtyRect: NSRect) {
    let selection = NSBezierPath(
      roundedRect: bounds.insetBy(dx: DS.Space.s2, dy: DS.Space.s1 / 2),
      xRadius: DS.Radius.md, yRadius: DS.Radius.md)
    NSColor(DS.Palette.sidebarSelected).setFill()
    selection.fill()
    if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
      NSColor(DS.Palette.primary).setStroke()
      selection.lineWidth = DS.Size.stroke
      selection.stroke()
    }
  }
}
