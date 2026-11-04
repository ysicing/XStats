// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import OSLog

/// 仅显示期间读取应用与图标；分页使控件和图标数量不随应用清单增长。
@MainActor
final class LaunchpadWindowController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
  private(set) var panel: NSPanel?
  private(set) var results: [AppCommand] = []
  private(set) var selectedIndex = 0
  private(set) var columns = 1
  private(set) var pageSize = 1
  private var search: CommandBarSearch?
  private var field: NSSearchField?
  private var grid: NSView?
  private var status: NSTextField?
  private var pageLabel: NSTextField?
  private var favoriteButton: NSButton?
  private var previousButton: NSButton?
  private var nextButton: NSButton?
  private var buttons: [NSButton] = []
  private var catalogTask: Task<Void, Never>?
  private var sessionID: UUID?
  private var language: AppLanguage = .system
  private let usage: CommandBarUsage?
  var onSelect: (AppCommand) -> Void = { _ in }
  var isVisible: Bool { panel?.isVisible == true }
  var page: Int { selectedIndex / pageSize }
  var pageCount: Int { max(1, (results.count + pageSize - 1) / pageSize) }

  init(usage: CommandBarUsage? = nil) {
    self.usage = usage
    super.init()
  }

  func show(
    language: AppLanguage = L10n.language, frame: NSRect? = nil,
    applicationLoader: @escaping @Sendable () throws -> [AppCommand] = {
      try CommandBarApplications.scan()
    }
  ) {
    if let panel {
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(field)
      return
    }
    self.language = language
    let screen =
      NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    guard let frame = frame ?? screen?.frame else { return }
    let session = UUID()
    sessionID = session
    let panel = LaunchpadPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    self.panel = panel
    panel.title = text("启动台")
    panel.identifier = NSUserInterfaceItemIdentifier("XStatsLaunchpad")
    panel.isReleasedWhenClosed = false
    panel.isRestorable = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .statusBar
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.hasShadow = false
    panel.animationBehavior = .none
    panel.delegate = self
    panel.onPage = { [weak self] delta in self?.changePage(by: delta) }
    panel.onDismiss = { [weak self] in self?.dismiss() }
    buildContent(size: frame.size)
    panel.setFrame(frame, display: false)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(field)
    NotificationCenter.default.addObserver(
      self, selector: #selector(dismiss), name: NSApplication.didChangeScreenParametersNotification,
      object: nil)

    catalogTask = Task { [weak self] in
      let worker = Task.detached(priority: .userInitiated) {
        let applications = try applicationLoader().filter {
          if case .openApplication = $0.action { return true }
          return false
        }
        try Task.checkCancellation()
        return CommandBarSearch(commands: applications, supportsParameterQueries: false)
      }
      let index: CommandBarSearch?
      do {
        index = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: {
          worker.cancel()
        }
      } catch {
        guard !Task.isCancelled, let self, self.sessionID == session else { return }
        self.catalogTask = nil
        self.status?.stringValue = self.text("无法读取应用，请关闭后重试。")
        Logger(subsystem: Log.subsystem, category: "Launchpad").error("Application catalog failed")
        return
      }
      guard !Task.isCancelled, let self, self.sessionID == session else { return }
      self.catalogTask = nil
      self.search = index
      self.refreshResults()
    }
  }

  @objc func dismiss() {
    sessionID = nil
    catalogTask?.cancel()
    catalogTask = nil
    NotificationCenter.default.removeObserver(
      self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    let closing = panel
    panel = nil
    closing?.delegate = nil
    closing?.orderOut(nil)
    closing?.close()
    closing?.contentView = nil
    search = nil
    results = []
    selectedIndex = 0
    field = nil
    grid = nil
    status = nil
    pageLabel = nil
    favoriteButton = nil
    previousButton = nil
    nextButton = nil
    buttons = []
  }

  func windowWillClose(_ notification: Notification) { dismiss() }
  func windowDidResignKey(_ notification: Notification) { dismiss() }

  func controlTextDidChange(_ notification: Notification) { refreshResults() }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard !textView.hasMarkedText() else { return false }
    switch selector {
    case #selector(NSResponder.moveLeft(_:)): moveSelection(by: isRTL ? 1 : -1)
    case #selector(NSResponder.moveRight(_:)): moveSelection(by: isRTL ? -1 : 1)
    case #selector(NSResponder.moveUp(_:)): moveSelection(by: -columns)
    case #selector(NSResponder.moveDown(_:)): moveSelection(by: columns)
    case #selector(NSResponder.pageUp(_:)): changePage(by: -1)
    case #selector(NSResponder.pageDown(_:)): changePage(by: 1)
    case #selector(NSResponder.insertNewline(_:)): executeSelection(nil)
    case #selector(NSResponder.cancelOperation(_:)): dismiss()
    default: return false
    }
    return true
  }

  func moveSelection(by delta: Int) {
    guard !results.isEmpty else { return }
    let previousPage = page
    selectedIndex = min(max(0, selectedIndex + delta), results.count - 1)
    if previousPage != page { renderPage() } else { updateSelection() }
  }

  func changePage(by delta: Int) {
    guard !results.isEmpty else { return }
    let target = min(max(0, page + delta), pageCount - 1)
    guard target != page else { return }
    selectedIndex = target * pageSize
    renderPage()
    panel?.makeFirstResponder(field)
  }

  private var isRTL: Bool { language.resolved.isRightToLeft }
  private func text(_ key: String) -> String { L10n.translate(key, language: language) }

  private func buildContent(size: NSSize) {
    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    background.material = .fullScreenUI
    background.blendingMode = .behindWindow
    background.state = .active
    background.userInterfaceLayoutDirection = isRTL ? .rightToLeft : .leftToRight
    panel?.contentView = background

    let field = NSSearchField()
    field.placeholderString = text("搜索应用")
    field.setAccessibilityLabel(field.placeholderString)
    field.controlSize = .large
    field.font = .systemFont(ofSize: DS.TextSize.lg.rawValue)
    field.maximumRecents = 0
    field.recentsAutosaveName = nil
    field.sendsSearchStringImmediately = true
    field.alignment = isRTL ? .right : .left
    field.userInterfaceLayoutDirection = background.userInterfaceLayoutDirection
    field.delegate = self
    self.field = field

    let title = NSTextField(labelWithString: text("启动台"))
    title.font = .systemFont(ofSize: DS.TextSize.xl.rawValue, weight: .semibold)
    let close = NSButton(
      image: NSImage(systemSymbolName: "xmark", accessibilityDescription: text("关闭"))!,
      target: self, action: #selector(dismiss))
    close.bezelStyle = .circular
    close.setAccessibilityLabel(text("关闭"))
    close.toolTip = text("关闭") + " (Esc)"
    close.keyEquivalent = "w"
    close.keyEquivalentModifierMask = .command

    columns = max(1, min(8, Int((size.width - 64) / 132)))
    let rows = max(1, min(6, Int((size.height - 240) / 132)))
    pageSize = columns * rows
    let grid = NSView()
    self.grid = grid
    let status = NSTextField(labelWithString: text("正在读取应用…"))
    status.alignment = .center
    status.textColor = .secondaryLabelColor
    self.status = status
    let pageLabel = NSTextField(labelWithString: "")
    pageLabel.alignment = .center
    pageLabel.font = .monospacedDigitSystemFont(ofSize: DS.TextSize.sm.rawValue, weight: .regular)
    self.pageLabel = pageLabel
    let previous = NSButton(
      image: NSImage(
        systemSymbolName: isRTL ? "chevron.right" : "chevron.left",
        accessibilityDescription: text("上一页"))!, target: self, action: #selector(previousPage))
    previous.setAccessibilityLabel(text("上一页"))
    let next = NSButton(
      image: NSImage(
        systemSymbolName: isRTL ? "chevron.left" : "chevron.right",
        accessibilityDescription: text("下一页"))!, target: self, action: #selector(nextPage))
    next.setAccessibilityLabel(text("下一页"))
    previousButton = previous
    nextButton = next
    let pager = NSStackView(views: [previous, pageLabel, next])
    pager.spacing = DS.Space.s4
    pager.userInterfaceLayoutDirection = background.userInterfaceLayoutDirection
    let favorite = NSButton(title: text("收藏"), target: self, action: #selector(toggleFavorite))
    favorite.keyEquivalent = "d"
    favorite.keyEquivalentModifierMask = .command
    favorite.bezelStyle = .rounded
    favoriteButton = favorite
    let footer = NSStackView(views: [pager, favorite])
    footer.spacing = DS.Space.s8
    footer.userInterfaceLayoutDirection = background.userInterfaceLayoutDirection

    for view in [title, field, close, grid, status, footer] {
      view.translatesAutoresizingMaskIntoConstraints = false
      background.addSubview(view)
    }
    NSLayoutConstraint.activate([
      title.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      title.topAnchor.constraint(equalTo: background.topAnchor, constant: 44),
      close.topAnchor.constraint(equalTo: background.topAnchor, constant: 40),
      close.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -32),
      field.topAnchor.constraint(equalTo: title.bottomAnchor, constant: DS.Space.s4),
      field.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      field.widthAnchor.constraint(equalToConstant: min(440, size.width - 112)),
      field.heightAnchor.constraint(equalToConstant: DS.Size.controlHeight),
      grid.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      grid.topAnchor.constraint(equalTo: field.bottomAnchor, constant: DS.Space.s6),
      grid.widthAnchor.constraint(equalToConstant: CGFloat(columns) * 132),
      grid.heightAnchor.constraint(equalToConstant: CGFloat(rows) * 132),
      status.centerXAnchor.constraint(equalTo: grid.centerXAnchor),
      status.centerYAnchor.constraint(equalTo: grid.centerYAnchor),
      footer.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -44),
      pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
    ])
    updateSelection()
  }

  private func refreshResults(preservingSelection: Bool = false) {
    guard let search else { return }
    let selectedID = results.indices.contains(selectedIndex) ? results[selectedIndex].id : nil
    results = search.results(for: field?.stringValue ?? "", favorites: usage?.favorites ?? [])
    selectedIndex = preservingSelection ? results.firstIndex { $0.id == selectedID } ?? 0 : 0
    status?.stringValue = text("没有匹配的项目")
    status?.isHidden = !results.isEmpty
    renderPage()
  }

  private func renderPage() {
    buttons.forEach { $0.removeFromSuperview() }
    buttons = []
    guard let grid else { return }
    grid.layoutSubtreeIfNeeded()
    // 图标仅随当前页的按钮存活，不保留所有页面的原始 NSImage。
    for index in (page * pageSize)..<min((page + 1) * pageSize, results.count) {
      let command = results[index]
      guard case .openApplication(let url) = command.action else { continue }
      let offset = index % pageSize
      let column = isRTL ? columns - 1 - offset % columns : offset % columns
      let button = NSButton(
        frame: NSRect(
          x: CGFloat(column) * 132 + 6,
          y: grid.bounds.height - CGFloat(offset / columns + 1) * 132 + 6,
          width: 120, height: 120))
      button.attributedTitle = NSAttributedString(
        string: command.title,
        attributes: [
          .font: NSFont.systemFont(ofSize: DS.TextSize.sm.rawValue),
          .foregroundColor: NSColor.labelColor,
        ])
      button.image = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
      button.image?.size = NSSize(width: 64, height: 64)
      button.imagePosition = .imageAbove
      button.imageScaling = .scaleProportionallyDown
      button.isBordered = false
      button.lineBreakMode = .byTruncatingTail
      button.toolTip = command.title
      button.setAccessibilityLabel(command.title)
      button.identifier = NSUserInterfaceItemIdentifier(command.id)
      button.tag = index
      button.target = self
      button.action = #selector(executeSelection(_:))
      button.wantsLayer = true
      button.layer?.cornerRadius = DS.Radius.lg
      grid.addSubview(button)
      buttons.append(button)
    }
    updateSelection()
  }

  private func updateSelection() {
    for button in buttons {
      let selected = button.tag == selectedIndex
      button.layer?.backgroundColor =
        selected ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : nil
      button.layer?.borderWidth = selected ? 2 : 0
      button.layer?.borderColor = NSColor.controlAccentColor.cgColor
      button.setAccessibilityValue(selected)
    }
    let selected = results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    let favorite = selected.map { usage?.favorites.contains($0.id) == true } ?? false
    favoriteButton?.title = text(favorite ? "取消收藏" : "收藏") + " ⌘D"
    favoriteButton?.isEnabled =
      selected != nil && usage != nil && (favorite || (usage?.favorites.count ?? 0) < 8)
    favoriteButton?.toolTip = text("最多收藏 8 项")
    pageLabel?.stringValue =
      "\( (page + 1).formatted(.number.locale(L10n.locale(for: language)))) / \(pageCount.formatted(.number.locale(L10n.locale(for: language))))"
    previousButton?.isEnabled = page > 0
    nextButton?.isEnabled = page + 1 < pageCount
  }

  @objc private func previousPage() { changePage(by: -1) }
  @objc private func nextPage() { changePage(by: 1) }

  @objc private func toggleFavorite() {
    guard results.indices.contains(selectedIndex),
      (field?.currentEditor() as? NSTextView)?.hasMarkedText() != true
    else { return }
    usage?.toggleFavorite(results[selectedIndex].id)
    refreshResults(preservingSelection: true)
    panel?.makeFirstResponder(field)
  }

  @objc private func executeSelection(_ sender: NSButton?) {
    let index = sender?.tag ?? selectedIndex
    guard results.indices.contains(index) else { return }
    let command = results[index]
    dismiss()
    onSelect(command)
  }
}

@MainActor
private final class LaunchpadPanel: NSPanel {
  var onPage: (Int) -> Void = { _ in }
  var onDismiss: () -> Void = {}
  private var scrollAmount: CGFloat = 0
  private var lastScrollTime: TimeInterval = 0
  private var lastPageTime: TimeInterval = 0

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
  override func cancelOperation(_ sender: Any?) { onDismiss() }

  override func sendEvent(_ event: NSEvent) {
    guard event.type == .scrollWheel else {
      super.sendEvent(event)
      return
    }
    guard event.momentumPhase.isEmpty else { return }
    if event.timestamp - lastScrollTime > 0.25 { scrollAmount = 0 }
    lastScrollTime = event.timestamp
    scrollAmount +=
      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
      ? event.scrollingDeltaX : event.scrollingDeltaY
    guard abs(scrollAmount) >= (event.hasPreciseScrollingDeltas ? 50 : 2),
      event.timestamp - lastPageTime > 0.3
    else { return }
    onPage(scrollAmount < 0 ? 1 : -1)
    scrollAmount = 0
    lastPageTime = event.timestamp
  }
}
