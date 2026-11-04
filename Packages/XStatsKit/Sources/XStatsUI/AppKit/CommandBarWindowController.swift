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
  private var hintLabel: NSTextField?
  private var favoriteButton: NSButton?
  private var catalogTask: Task<Void, Never>?
  private var sessionID: UUID?
  private var language: AppLanguage = .system
  private var icons: [URL: NSImage] = [:]
  private var hasMovedSelection = false
  private let usage: CommandBarUsage?
  var onSelect: (AppCommand) -> Void = { _ in }
  var isVisible: Bool { panel?.isVisible == true }

  init(usage: CommandBarUsage? = nil) {
    self.usage = usage
    super.init()
  }

  func recordUsage(_ command: AppCommand) { usage?.record(command) }

  func show(
    commands: [AppCommand], language: AppLanguage = L10n.language,
    applicationLoader: (@Sendable () throws -> [AppCommand])? = nil
  ) {
    if let panel {
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(searchField)
      return
    }
    self.language = language
    hasMovedSelection = false
    let session = UUID()
    sessionID = session
    search = CommandBarSearch(commands: commands)
    results =
      search?.results(for: "", favorites: usage?.favorites ?? [], recent: usage?.recent ?? []) ?? []
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
    field.placeholderString = L10n.translate("搜索应用、功能与操作", language: language)
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

    let hint = NSTextField(labelWithString: "")
    hint.font = .systemFont(ofSize: DS.TextSize.xs.rawValue)
    hint.textColor = .secondaryLabelColor
    hint.lineBreakMode = .byTruncatingTail
    hint.userInterfaceLayoutDirection = direction
    hint.alignment = direction == .rightToLeft ? .right : .left
    hintLabel = hint

    let favorite = NSButton(title: "", target: self, action: #selector(toggleFavorite))
    favorite.bezelStyle = .inline
    favorite.keyEquivalent = "d"
    favorite.keyEquivalentModifierMask = .command
    favorite.isHidden = usage == nil
    favoriteButton = favorite

    let more = NSPopUpButton()
    more.pullsDown = true
    more.bezelStyle = .inline
    more.addItem(withTitle: "…")
    more.setAccessibilityLabel(L10n.translate("更多", language: language))
    let clear = NSMenuItem(
      title: L10n.translate("清除最近使用", language: language),
      action: #selector(clearRecent), keyEquivalent: "")
    clear.target = self
    more.menu?.addItem(clear)
    let clearFavorites = NSMenuItem(
      title: L10n.translate("清除收藏", language: language),
      action: #selector(clearFavorites), keyEquivalent: "")
    clearFavorites.target = self
    more.menu?.addItem(clearFavorites)
    more.isHidden = usage == nil

    for view in [searchBackground, searchIcon, field, scroll, empty, hint, favorite, more] {
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
      scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
      hint.leadingAnchor.constraint(equalTo: searchBackground.leadingAnchor),
      hint.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
      hint.trailingAnchor.constraint(lessThanOrEqualTo: favorite.leadingAnchor, constant: -8),
      favorite.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
      favorite.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -8),
      more.trailingAnchor.constraint(equalTo: searchBackground.trailingAnchor),
      more.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
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
    if let applicationLoader {
      hint.stringValue = L10n.translate("正在读取应用…", language: language)
      catalogTask = Task { [weak self] in
        let worker = Task.detached(priority: .userInitiated) {
          let applications = try applicationLoader()
          try Task.checkCancellation()
          return CommandBarSearch(commands: commands + applications)
        }
        let index = await withTaskCancellationHandler {
          try? await worker.value
        } onCancel: {
          worker.cancel()
        }
        guard !Task.isCancelled, let self, self.sessionID == session else { return }
        if let index { self.search = index }
        self.catalogTask = nil
        let hasQuery =
          self.searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          == false
        self.refreshResults(preservingSelection: self.hasMovedSelection || hasQuery)
      }
    }
  }

  func dismiss() {
    catalogTask?.cancel()
    catalogTask = nil
    sessionID = nil
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
    icons = [:]
    hintLabel = nil
    favoriteButton = nil
  }

  func windowDidResignKey(_ notification: Notification) { dismiss() }
  func windowWillClose(_ notification: Notification) { dismiss() }

  func controlTextDidChange(_ notification: Notification) {
    refreshResults()
  }

  private func refreshResults(preservingSelection: Bool = false) {
    guard let field = searchField, let search else { return }
    let selectedID = selectedCommand?.id
    results = search.results(
      for: field.stringValue, favorites: usage?.favorites ?? [], recent: usage?.recent ?? [])
    reloadResults(selectedID: preservingSelection ? selectedID : nil)
  }

  private var selectedCommand: AppCommand? {
    guard let row = table?.selectedRow, results.indices.contains(row) else { return nil }
    return results[row]
  }

  private func reloadResults(selectedID: String? = nil) {
    table?.reloadData()
    emptyLabel?.isHidden = !results.isEmpty
    scroll?.isHidden = results.isEmpty
    if !results.isEmpty {
      let row = results.firstIndex { $0.id == selectedID } ?? 0
      table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      table?.scrollRowToVisible(row)
    }
    updateFooter()
  }

  func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }

  private func updateFooter() {
    let prefix = searchField?.stringValue.lowercased().split(whereSeparator: \.isWhitespace).first
    let hint: String
    switch prefix {
    case "port": hint = L10n.translate("port <端口号 1–65535>", language: language)
    case "brew": hint = L10n.translate("brew <软件包名>", language: language)
    case "ps": hint = L10n.translate("ps <进程名或 PID>", language: language)
    default: hint = L10n.translate("↑↓ 选择 · ↩ 打开", language: language)
    }
    hintLabel?.stringValue = hint
    hintLabel?.toolTip = hint
    let favorite = selectedCommand.map { usage?.favorites.contains($0.id) == true } ?? false
    favoriteButton?.title = L10n.translate(favorite ? "取消收藏" : "收藏", language: language) + " ⌘D"
    favoriteButton?.image = NSImage(
      systemSymbolName: favorite ? "star.fill" : "star", accessibilityDescription: nil)
    favoriteButton?.imagePosition = .imageLeading
    favoriteButton?.isEnabled =
      selectedCommand.map {
        $0.id == $0.usageID && (favorite || (usage?.favorites.count ?? 0) < 8)
      } ?? false
    favoriteButton?.toolTip = L10n.translate("最多收藏 8 项", language: language)
  }

  @objc private func toggleFavorite() {
    guard let command = selectedCommand, command.id == command.usageID,
      (searchField?.currentEditor() as? NSTextView)?.hasMarkedText() != true
    else { return }
    usage?.toggleFavorite(command.id)
    refreshResults(preservingSelection: true)
  }

  @objc private func clearRecent() {
    usage?.clearRecent()
    refreshResults(preservingSelection: true)
  }

  @objc private func clearFavorites() {
    usage?.clearFavorites()
    refreshResults(preservingSelection: true)
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
    hasMovedSelection = true
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
    if case .openApplication(let url) = command.action {
      if icons[url] == nil {
        if icons.count >= 64 { icons.removeAll(keepingCapacity: true) }
        icons[url] = NSWorkspace.shared.icon(forFile: url.path)
      }
      cell.imageView?.image = icons[url]
      cell.imageView?.contentTintColor = nil
      cell.toolTip = url.path
    } else {
      cell.imageView?.image = NSImage(
        systemSymbolName: command.symbol, accessibilityDescription: nil)
      cell.imageView?.contentTintColor = NSColor(DS.Palette.textSecondary)
      cell.toolTip = command.title
    }
    let badge = cell.subviews.first { $0.identifier?.rawValue == "badge" } as? NSTextField
    let badgeTitle: String
    if usage?.favorites.contains(command.id) == true {
      badgeTitle = "收藏"
    } else if usage?.recent.contains(command.id) == true {
      badgeTitle = "最近使用"
    } else if case .openApplication = command.action {
      badgeTitle = "应用"
    } else {
      badgeTitle = ""
    }
    badge?.stringValue = L10n.translate(badgeTitle, language: language)
    return cell
  }

  private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let image = NSImageView()
    image.contentTintColor = NSColor(DS.Palette.textSecondary)
    image.symbolConfiguration = .init(pointSize: DS.Size.iconInline, weight: .regular)
    let label = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    badge.identifier = NSUserInterfaceItemIdentifier("badge")
    badge.font = .systemFont(ofSize: DS.TextSize.xs.rawValue)
    badge.textColor = .secondaryLabelColor
    badge.setContentCompressionResistancePriority(.required, for: .horizontal)
    label.font = .systemFont(ofSize: DS.TextSize.sm.rawValue, weight: .medium)
    label.textColor = NSColor(DS.Palette.textPrimary)
    label.lineBreakMode = .byTruncatingTail
    cell.userInterfaceLayoutDirection = table?.userInterfaceLayoutDirection ?? .leftToRight
    label.userInterfaceLayoutDirection = cell.userInterfaceLayoutDirection
    label.alignment = cell.userInterfaceLayoutDirection == .rightToLeft ? .right : .left
    for view in [image, label, badge] {
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
      label.trailingAnchor.constraint(
        lessThanOrEqualTo: badge.leadingAnchor, constant: -DS.Space.s3),
      badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -DS.Space.s4),
      badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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
