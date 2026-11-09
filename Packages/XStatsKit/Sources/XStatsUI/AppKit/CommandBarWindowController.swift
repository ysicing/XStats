// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import QuickLookUI
import UniformTypeIdentifiers

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
  /// 固定命令的索引（含拼音转换）在面板关闭后保留；命令集或语言变化时重建。
  private var fixedIndex: (signature: [String], language: AppLanguage, search: CommandBarSearch)?
  private var results: [AppCommand] = []
  private var hintLabel: NSTextField?
  private var favoriteButton: NSButton?
  private var actionsButton: NSButton?
  private(set) var previewPanel: NSPanel?
  private var catalogTask: Task<Void, Never>?
  private var catalogRequestID: UUID?
  private var catalogCommands: [AppCommand] = []
  private var applicationLoader: (@Sendable () throws -> [AppCommand])?
  private var includesApplications = false
  private var liveTask: Task<Void, Never>?
  private var liveRequest: CommandBarLiveRequest?
  private var processTargets: [CommandBarProcessTarget]?
  let fileSearch = CommandBarFileSearch()
  private let processLoader: @Sendable (Set<Int32>) throws -> [CommandBarProcessTarget]
  private var sessionID: UUID?
  private var language: AppLanguage = .system
  private var hasMovedSelection = false
  private let usage: CommandBarUsage?
  var onSelect: (AppCommand) -> Void = { _ in }
  var isVisible: Bool { panel?.isVisible == true }

  init(
    usage: CommandBarUsage? = nil,
    processLoader: @escaping @Sendable (Set<Int32>) throws -> [CommandBarProcessTarget] =
      CommandBarProcessTarget.snapshot
  ) {
    self.usage = usage
    self.processLoader = processLoader
    super.init()
  }

  func recordUsage(_ command: AppCommand) { usage?.record(command) }

  func show(
    commands: [AppCommand], language: AppLanguage = L10n.language,
    includesApplications: Bool = false,
    applicationLoader: (@Sendable () throws -> [AppCommand])? = nil
  ) {
    if let panel {
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(searchField)
      return
    }
    self.language = language
    self.includesApplications = includesApplications
    self.applicationLoader = applicationLoader
    catalogCommands = commands
    hasMovedSelection = false
    let session = UUID()
    sessionID = session
    // 标题已按当前语言翻译，签名同时覆盖命令集与语言变化。
    let signature = commands.map { "\($0.id)\u{0}\($0.title)" }
    if let fixedIndex, fixedIndex.signature == signature, fixedIndex.language == language {
      search = fixedIndex.search
    } else {
      let index = CommandBarSearch(commands: commands)
      fixedIndex = (signature, language, index)
      search = index
    }
    results =
      search?.results(for: "", favorites: usage?.favorites ?? [], recent: usage?.recent ?? []) ?? []
    let panel = CommandBarPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 432),
      styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    self.panel = panel
    panel.onPreview = { [weak self] in self?.togglePreview() ?? false }
    panel.onCancel = { [weak self] in self?.dismiss() }
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
    if includesApplications {
      let refresh = NSMenuItem(
        title: L10n.translate("刷新应用", language: language),
        action: #selector(refreshApplications), keyEquivalent: "")
      refresh.target = self
      more.menu?.addItem(.separator())
      more.menu?.addItem(refresh)
    }
    more.isHidden = usage == nil && !includesApplications
    let actions = NSButton(
      title: L10n.translate("动作", language: language) + " ⌘K",
      target: self, action: #selector(showActions))
    actions.keyEquivalent = "k"
    actions.keyEquivalentModifierMask = [.command]
    actions.bezelStyle = .inline
    actions.isHidden = true
    actionsButton = actions

    for view in [searchBackground, searchIcon, field, scroll, empty, hint, actions, favorite, more]
    {
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
      hint.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
      actions.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
      actions.trailingAnchor.constraint(equalTo: favorite.leadingAnchor, constant: -8),
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
    if includesApplications || applicationLoader != nil {
      _ = LauncherApplicationCatalog.shared
      NotificationCenter.default.addObserver(
        self, selector: #selector(reloadApplications),
        name: .launcherApplicationsChanged, object: nil)
      reloadApplications()
    }
  }

  @objc private func refreshApplications() {
    NotificationCenter.default.post(name: .launcherApplicationsChanged, object: nil)
  }

  @objc private func reloadApplications() {
    guard panel != nil else { return }
    catalogTask?.cancel()
    let request = UUID()
    catalogRequestID = request
    let session = sessionID
    let commands = catalogCommands
    let loader = applicationLoader
    hintLabel?.stringValue = L10n.translate("正在读取应用…", language: language)
    catalogTask = Task { [weak self] in
      do {
        let applications: [AppCommand]
        if let loader {
          let scan = Task.detached(priority: .userInitiated) { try loader() }
          applications = try await withTaskCancellationHandler {
            try await scan.value
          } onCancel: {
            scan.cancel()
          }
        } else {
          applications = try await LauncherApplicationCatalog.shared.load().commands
        }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
          try Task.checkCancellation()
          return CommandBarSearch(commands: commands + applications)
        }
        let index = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: {
          worker.cancel()
        }
        guard !Task.isCancelled, let self, self.sessionID == session,
          self.catalogRequestID == request
        else { return }
        self.search = index
        self.catalogTask = nil
        let hasQuery =
          self.searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          == false
        self.refreshResults(preservingSelection: self.hasMovedSelection || hasQuery)
      } catch {
        guard !Task.isCancelled, let self, self.sessionID == session,
          self.catalogRequestID == request
        else { return }
        self.catalogTask = nil
        self.hintLabel?.stringValue = L10n.translate("无法读取应用，请关闭后重试。", language: self.language)
      }
    }
  }

  func dismiss() {
    closePreview(restoringFocus: false)
    cancelLiveSearch()
    catalogTask?.cancel()
    catalogTask = nil
    catalogRequestID = nil
    catalogCommands = []
    applicationLoader = nil
    NotificationCenter.default.removeObserver(
      self, name: .launcherApplicationsChanged, object: nil)
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
    hintLabel = nil
    favoriteButton = nil
    actionsButton = nil
  }

  func windowDidResignKey(_ notification: Notification) {
    guard previewPanel != nil else {
      dismiss()
      return
    }
    let session = sessionID
    // 失焦通知先于新窗口获得焦点；下一轮再区分内部切换和离开整个命令栏。
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, self.sessionID == session else { return }
      guard self.panel?.isKeyWindow != true, self.previewPanel?.isKeyWindow != true else {
        return
      }
      self.dismiss()
    }
  }

  func windowWillClose(_ notification: Notification) {
    if notification.object as? NSWindow === previewPanel {
      closePreview(restoringFocus: true)
    } else {
      dismiss()
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    refreshResults()
  }

  private func refreshResults(preservingSelection: Bool = false) {
    guard let field = searchField, let search else { return }
    let selectedID = selectedCommand?.id
    if let request = CommandBarLiveRequest(field.stringValue) {
      refreshLiveResults(request, selectedID: preservingSelection ? selectedID : nil)
      return
    }
    cancelLiveSearch()
    results = search.results(
      for: field.stringValue, favorites: usage?.favorites ?? [], recent: usage?.recent ?? [])
    reloadResults(selectedID: preservingSelection ? selectedID : nil)
  }

  private func cancelLiveSearch(keepingFileIndex: Bool = false) {
    liveTask?.cancel()
    liveTask = nil
    fileSearch.stop(keepingPinyinIndex: keepingFileIndex)
    liveRequest = nil
    processTargets = nil
  }

  private func refreshLiveResults(_ request: CommandBarLiveRequest, selectedID: String?) {
    let previous = liveRequest
    switch request {
    case .files(let text), .revealFiles(let text):
      guard request != previous else {
        updateFooter()
        return
      }
      let keepingFileIndex: Bool
      switch previous {
      case .files, .revealFiles: keepingFileIndex = true
      default: keepingFileIndex = false
      }
      cancelLiveSearch(keepingFileIndex: keepingFileIndex)
      liveRequest = request
      results = []
      reloadResults()
      guard CommandBarFileSearch.predicate(text) != nil else {
        emptyLabel?.stringValue = L10n.translate("输入文件名以搜索", language: language)
        return
      }
      emptyLabel?.stringValue = L10n.translate("正在搜索…", language: language)
      let session = sessionID
      liveTask = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        guard let self, self.sessionID == session, self.liveRequest == request else { return }
        self.fileSearch.start(text) { [weak self] commands in
          guard let self, self.sessionID == session, self.liveRequest == request else { return }
          let selection = self.hasMovedSelection ? self.selectedCommand?.id : nil
          self.results = commands.map { command in
            guard case .revealFiles = request, let url = command.fileURL else { return command }
            return AppCommand(
              id: command.id, title: command.title, symbol: command.symbol,
              keywords: command.keywords, action: .revealFile(url),
              subtitle: command.subtitle, badge: command.badge)
          }
          self.emptyLabel?.stringValue = L10n.translate(
            "没有匹配的项目", language: self.language)
          self.reloadResults(selectedID: selection)
        }
      }
    case .processes(let text):
      if case .processes = previous {
        liveRequest = request
      } else {
        cancelLiveSearch()
        liveRequest = request
        let excluded = Set(
          NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
          }.map(\.processIdentifier))
        let loader = processLoader
        let session = sessionID
        liveTask = Task { [weak self] in
          let worker = Task.detached(priority: .userInitiated) {
            let targets = try loader(excluded)
            try Task.checkCancellation()
            return targets
          }
          let targets = await withTaskCancellationHandler {
            try? await worker.value
          } onCancel: {
            worker.cancel()
          }
          guard !Task.isCancelled, let self, self.sessionID == session,
            case .processes = self.liveRequest
          else { return }
          self.liveTask = nil
          self.processTargets = targets ?? []
          self.refreshResults(preservingSelection: true)
        }
      }
      results = Array((processTargets ?? []).lazy.filter { $0.matches(text) }.prefix(50))
        .map { $0.command(language: language) }
      emptyLabel?.stringValue = L10n.translate(
        processTargets == nil ? "正在读取进程…" : "没有匹配的项目", language: language)
      reloadResults(selectedID: selectedID)
    }
  }

  private var selectedCommand: AppCommand? {
    guard let row = table?.selectedRow, results.indices.contains(row) else { return nil }
    return results[row]
  }

  private func reloadResults(selectedID: String? = nil) {
    table?.rowHeight =
      results.contains { !$0.subtitle.isEmpty } ? 52 : DS.Size.controlHeight + DS.Space.s2
    if liveRequest == nil {
      emptyLabel?.stringValue = L10n.translate("没有匹配的项目", language: language)
    }
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
    case "kill": hint = L10n.translate("↑↓ 选择 · ↩ 结束", language: language)
    case "find": hint = L10n.translate("↩ 在访达中显示 · ⌘Y 快速查看", language: language)
    case "open": hint = L10n.translate("↩ 打开 · ⌘Y 快速查看", language: language)
    default: hint = L10n.translate("↑↓ 选择 · ↩ 打开", language: language)
    }
    hintLabel?.stringValue = hint
    hintLabel?.toolTip = hint
    let supportsActions: Bool
    switch selectedCommand?.action {
    case .openFile, .revealFile, .terminateProcess: supportsActions = true
    default: supportsActions = false
    }
    actionsButton?.isHidden = !supportsActions
    actionsButton?.isEnabled = selectedCommand != nil
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
    if case .completeQuery(let query) = command.action {
      searchField?.stringValue = query
      refreshResults()
      panel?.makeFirstResponder(searchField)
      return
    }
    dismiss()
    onSelect(command)
  }

  @objc private func showActions(_ sender: NSButton) {
    guard let menu = resultActionsMenu() else { return }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
  }

  func resultActionsMenu() -> NSMenu? {
    guard let command = selectedCommand, let session = sessionID,
      (searchField?.currentEditor() as? NSTextView)?.hasMarkedText() != true
    else { return nil }
    let entries: [(String, Int)]
    switch command.action {
    case .openFile, .revealFile:
      entries = [
        ("打开", 0), ("在访达中显示", 1), ("快速查看", 4),
        ("打开方式", 5), ("拷贝路径", 2), ("移到废纸篓", 6),
      ]
    case .terminateProcess:
      entries = [("结束进程", 0), ("强制退出", 3), ("拷贝 PID", 2)]
    default: return nil
    }
    let menu = NSMenu()
    for (title, tag) in entries {
      let item = NSMenuItem(
        title: L10n.translate(title, language: language),
        action: #selector(performResultAction), keyEquivalent: "")
      item.tag = tag
      item.target = self
      item.representedObject = (session, command)
      if tag == 4 {
        item.keyEquivalent = "y"
        item.keyEquivalentModifierMask = .command
      }
      if tag == 5, let url = command.fileURL {
        let apps = NSMenu()
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(20) {
          let entry = NSMenuItem(
            title: app.deletingPathExtension().lastPathComponent,
            action: #selector(openWithApplication), keyEquivalent: "")
          entry.target = self
          entry.representedObject = (session, command, app)
          apps.addItem(entry)
        }
        let other = NSMenuItem(
          title: L10n.translate("其他…", language: language),
          action: #selector(performResultAction), keyEquivalent: "")
        other.tag = 5
        other.target = self
        other.representedObject = (session, command)
        apps.addItem(other)
        item.submenu = apps
      }
      menu.addItem(item)
    }
    return menu
  }

  @objc private func openWithApplication(_ sender: NSMenuItem) {
    guard
      let (session, command, application) = sender.representedObject as? (UUID, AppCommand, URL),
      sessionID == session, selectedCommand?.id == command.id, let url = command.fileURL
    else { return }
    dismiss()
    CommandBarFileActions.open(url, using: application)
  }

  @objc private func performResultAction(_ sender: NSMenuItem) {
    guard let (session, command) = sender.representedObject as? (UUID, AppCommand),
      sessionID == session, selectedCommand?.id == command.id
    else { return }
    if sender.tag == 4 {
      _ = togglePreview()
      return
    }
    if sender.tag == 2 {
      let value: String
      switch command.action {
      case .openFile(let url), .revealFile(let url): value = url.path
      case .terminateProcess(let target): value = String(target.process.pid)
      default: return
      }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
      return
    }
    dismiss()
    if let url = command.fileURL {
      switch sender.tag {
      case 0:
        onSelect(
          AppCommand(
            id: command.id, title: command.title, symbol: command.symbol,
            keywords: command.keywords, action: .openFile(url)))
      case 1: NSWorkspace.shared.activateFileViewerSelecting([url])
      case 5: CommandBarFileActions.chooseApplication(for: url)
      case 6: CommandBarFileActions.confirmTrash(url)
      default: break
      }
    } else if sender.tag == 3, case .terminateProcess(let target) = command.action {
      CommandBarProcessActions.confirm(target, force: true)
    } else {
      onSelect(command)
    }
  }

  @discardableResult
  func togglePreview() -> Bool {
    guard (searchField?.currentEditor() as? NSTextView)?.hasMarkedText() != true else {
      return false
    }
    if previewPanel != nil {
      closePreview(restoringFocus: true)
      return true
    }
    guard let command = selectedCommand, let url = command.fileURL, let panel,
      FileManager.default.fileExists(atPath: url.path),
      let view = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), style: .normal)
    else { return false }
    let preview = CommandBarPanel(
      contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
      backing: .buffered, defer: false)
    preview.isReleasedWhenClosed = false
    preview.title = command.title
    preview.contentView = view
    preview.delegate = self
    preview.level = .floating
    preview.onPreview = { [weak self] in
      self?.closePreview(restoringFocus: true)
      return true
    }
    preview.onCancel = { [weak self] in self?.closePreview(restoringFocus: true) }
    previewPanel = preview
    view.autostarts = false
    view.previewItem = url as NSURL
    preview.setFrameOrigin(
      NSPoint(x: panel.frame.midX - 320, y: panel.frame.midY - 240))
    preview.makeKeyAndOrderFront(nil)
    return true
  }

  private func closePreview(restoringFocus: Bool) {
    guard let preview = previewPanel else { return }
    previewPanel = nil
    preview.delegate = nil
    (preview.contentView as? QLPreviewView)?.close()
    preview.orderOut(nil)
    preview.close()
    preview.contentView = nil
    if restoringFocus {
      panel?.makeKeyAndOrderFront(nil)
      panel?.makeFirstResponder(searchField)
    }
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
    let subtitle =
      (cell.subviews.first { $0 is NSStackView } as? NSStackView)?
      .arrangedSubviews.last as? NSTextField
    subtitle?.stringValue = command.subtitle
    subtitle?.isHidden = command.subtitle.isEmpty
    if case .openApplication(let url) = command.action {
      cell.imageView?.image = LauncherIconCache.shared.image(for: url, size: 32)
      cell.imageView?.contentTintColor = nil
      cell.toolTip = url.path
    } else if let url = command.fileURL {
      let type =
        url.hasDirectoryPath
        ? UTType.folder : (UTType(filenameExtension: url.pathExtension) ?? .data)
      cell.imageView?.image = NSWorkspace.shared.icon(for: type)
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
    if !command.badge.isEmpty {
      badgeTitle = command.badge
    } else if usage?.favorites.contains(command.id) == true {
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
    let subtitle = NSTextField(labelWithString: "")
    subtitle.font = .systemFont(ofSize: DS.TextSize.xs.rawValue)
    subtitle.textColor = .secondaryLabelColor
    subtitle.lineBreakMode = .byTruncatingMiddle
    subtitle.isHidden = true
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
    subtitle.alignment = label.alignment
    let text = NSStackView(views: [label, subtitle])
    text.orientation = .vertical
    text.alignment = cell.userInterfaceLayoutDirection == .rightToLeft ? .trailing : .leading
    text.spacing = 2
    for view in [image, text, badge] {
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
      text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: DS.Space.s3),
      text.trailingAnchor.constraint(
        lessThanOrEqualTo: badge.leadingAnchor, constant: -DS.Space.s3),
      badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -DS.Space.s4),
      badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      label.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
      subtitle.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
    ])
    return cell
  }
}

private final class CommandBarPanel: NSPanel {
  var onPreview: () -> Bool = { false }
  var onCancel: () -> Void = {}

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
      event.charactersIgnoringModifiers?.lowercased() == "y", onPreview()
    {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func cancelOperation(_ sender: Any?) { onCancel() }
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
