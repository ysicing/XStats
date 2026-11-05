// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import OSLog
import QuartzCore

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
  private var wallpaperTask: Task<Void, Never>?
  private var removalTask: Task<Void, Never>?
  private var applicationMap: [String: AppCommand] = [:]
  private var displayPages: [[AppCommand]] = []
  private(set) var layout = LaunchpadLayout()
  private(set) var folderID: String?
  private(set) var isEditing = false
  private(set) var isRevealing = false
  private var editButton: NSButton?
  private var backButton: NSButton?
  private var renameButton: NSButton?
  private var heading: NSTextField?
  private var candidates = Set<String>()
  private var pendingDeletion = false
  private var revealAnimationID: UUID?
  private var revealTimeoutTask: Task<Void, Never>?
  private var lastRevealUpdate = ContinuousClock.now
  private var dragZones: [LaunchpadDropView] = []
  private var sessionID: UUID?
  private var language: AppLanguage = .system
  private let usage: CommandBarUsage?
  private let layoutStore: LaunchpadLayoutStore?
  var onSelect: (AppCommand) -> Void = { _ in }
  var isVisible: Bool { panel?.isVisible == true }
  var page: Int {
    var offset = 0
    for (index, items) in displayPages.enumerated() {
      offset += items.count
      if selectedIndex < offset { return index }
    }
    return 0
  }
  var pageCount: Int { max(1, displayPages.count) }

  func setRevealProgress(_ progress: Double) {
    guard let panel else { return }
    isRevealing = true
    revealAnimationID = nil
    lastRevealUpdate = .now
    if revealTimeoutTask == nil {
      let session = sessionID
      revealTimeoutTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(1)) } catch { return }
          guard let self, self.sessionID == session else { return }
          if ContinuousClock.now - self.lastRevealUpdate > .milliseconds(1500) {
            self.finishReveal(commit: false)
            return
          }
        }
      }
    }
    let value = min(1, max(0, progress))
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }
    panel.alphaValue = value
    let scale = 1.12 - 0.12 * value
    let size = grid?.bounds.size ?? .zero
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    grid?.layer?.setAffineTransform(
      CGAffineTransform(
        translationX: size.width * (1 - scale) / 2,
        y: size.height * (1 - scale) / 2
      ).scaledBy(x: scale, y: scale))
    CATransaction.commit()
  }

  func finishReveal(commit: Bool) {
    guard let panel else { return }
    isRevealing = false
    revealTimeoutTask?.cancel()
    revealTimeoutTask = nil
    let session = sessionID
    let animation = UUID()
    revealAnimationID = animation
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
      panel.animator().alphaValue = commit ? 1 : 0
      grid?.layer?.setAffineTransform(.identity)
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.sessionID == session, self.revealAnimationID == animation else {
          return
        }
        self.revealAnimationID = nil
        if !commit { self.dismiss() }
      }
    }
  }

  init(usage: CommandBarUsage? = nil, layoutStore: LaunchpadLayoutStore? = nil) {
    self.usage = usage
    self.layoutStore = layoutStore
    super.init()
  }

  func show(
    language: AppLanguage = L10n.language, frame: NSRect? = nil,
    wallpaperURL: URL? = nil,
    applicationLoader: (@Sendable () throws -> [AppCommand])? = nil
  ) {
    guard frame != nil || LaunchpadAvailability.isSupported else { return }
    if let panel {
      finishReveal(commit: true)
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
    panel.onDismiss = { [weak self] in self?.goBack() }
    buildContent(size: frame.size)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
      let wallpaperURL = wallpaperURL
        ?? (frame == screen?.frame
          ? screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) } : nil)
    {
      wallpaperTask = Task { [weak self] in
        let worker = Task.detached(priority: .userInitiated) {
          try LaunchpadWallpaper.image(at: wallpaperURL)
        }
        let image = try? await withTaskCancellationHandler {
          try await worker.value
        } onCancel: {
          worker.cancel()
        }
        guard !Task.isCancelled, let self, self.sessionID == session,
          !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
          let image, let content = self.panel?.contentView
        else { return }
        let backdrop = NSView(frame: content.bounds)
        backdrop.identifier = NSUserInterfaceItemIdentifier("launchpad.wallpaper")
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.contents = image
        backdrop.layer?.contentsGravity = .resizeAspectFill
        backdrop.layer?.masksToBounds = true
        let shade = NSView(frame: backdrop.bounds)
        shade.autoresizingMask = [.width, .height]
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        backdrop.addSubview(shade)
        content.addSubview(backdrop, positioned: .below, relativeTo: content.subviews.first)
        content.appearance = NSAppearance(named: .darkAqua)
        self.wallpaperTask = nil
      }
    }
    panel.setFrame(frame, display: false)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(field)
    NotificationCenter.default.addObserver(
      self, selector: #selector(dismiss), name: NSApplication.didChangeScreenParametersNotification,
      object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(displayOptionsChanged),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

    let savedLayout = layoutStore?.load()
    let importsSystemLayout = layoutStore != nil && savedLayout == nil
    catalogTask = Task { [weak self] in
      let worker = Task.detached(priority: .userInitiated) {
        // 默认扫描能报告是否触顶；自定义加载器仅能以数量达到上限推断。
        let scanned: (commands: [AppCommand], isTruncated: Bool)
        if let applicationLoader {
          let commands = try applicationLoader()
          scanned = (commands, commands.count >= CommandBarApplications.maxApplications)
        } else {
          scanned = try CommandBarApplications.scanResult()
        }
        let applications = scanned.commands.filter {
          if case .openApplication = $0.action { return true }
          return false
        }
        try Task.checkCancellation()
        let imported =
          importsSystemLayout
          ? try? LaunchpadImport.systemLayout(applications: applications) : nil
        let candidates = Set(
          applications.compactMap { command -> String? in
            guard case .openApplication(let url) = command.action,
              LaunchpadApplicationRemoval.isCandidate(url)
            else { return nil }
            return command.id
          })
        return (
          CommandBarSearch(commands: applications, supportsParameterQueries: false),
          applications, imported, candidates, scanned.isTruncated
        )
      }
      do {
        let (index, applications, imported, candidates, isTruncated) =
          try await withTaskCancellationHandler {
            try await worker.value
          } onCancel: {
            worker.cancel()
          }
        guard !Task.isCancelled, let self, self.sessionID == session else { return }
        self.catalogTask = nil
        self.search = index
        self.applicationMap = Dictionary(
          applications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.candidates = candidates
        if importsSystemLayout {
          Logger(subsystem: Log.subsystem, category: "Launchpad").info(
            "Initial layout loaded; system layout available: \(imported != nil)")
        }
        self.layout = savedLayout ?? imported ?? LaunchpadLayout()
        // 扫描触顶时缺失不等于已卸载：保留已有布局项，也不落盘，避免永久丢失用户整理结果。
        self.layout.reconcile(
          appIDs: index.results(for: "", favorites: self.usage?.favorites ?? []).map(\.id),
          capacity: self.pageSize, pruneMissing: !isTruncated)
        if !applications.isEmpty && !isTruncated { self.layoutStore?.save(self.layout) }
        self.refreshResults()
      } catch {
        guard !Task.isCancelled, let self, self.sessionID == session else { return }
        self.catalogTask = nil
        self.status?.stringValue = self.text("无法读取应用，请关闭后重试。")
        Logger(subsystem: Log.subsystem, category: "Launchpad").error("Application catalog failed")
        return
      }
    }
  }

  @objc func dismiss() {
    sessionID = nil
    isRevealing = false
    revealAnimationID = nil
    revealTimeoutTask?.cancel()
    revealTimeoutTask = nil
    catalogTask?.cancel()
    catalogTask = nil
    wallpaperTask?.cancel()
    wallpaperTask = nil
    removalTask?.cancel()
    removalTask = nil
    NotificationCenter.default.removeObserver(
      self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    NSWorkspace.shared.notificationCenter.removeObserver(
      self, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    let closing = panel
    panel = nil
    closing?.delegate = nil
    if let sheet = closing?.attachedSheet { closing?.endSheet(sheet, returnCode: .abort) }
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
    displayPages = []
    applicationMap = [:]
    layout = LaunchpadLayout()
    folderID = nil
    isEditing = false
    candidates = []
    editButton = nil
    backButton = nil
    renameButton = nil
    heading = nil
    pendingDeletion = false
    dragZones = []
  }

  func windowWillClose(_ notification: Notification) { dismiss() }
  func windowDidResignKey(_ notification: Notification) {
    if panel?.attachedSheet == nil && !pendingDeletion { dismiss() }
  }

  func controlTextDidChange(_ notification: Notification) { refreshResults() }

  @objc private func displayOptionsChanged() {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
      wallpaperTask?.cancel()
      wallpaperTask = nil
      panel?.contentView?.subviews.filter {
        $0.identifier?.rawValue == "launchpad.wallpaper"
      }.forEach { $0.removeFromSuperview() }
      panel?.contentView?.appearance = nil
    }
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      panel?.alphaValue = 1
      grid?.layer?.setAffineTransform(.identity)
    }
    renderPage()
  }

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
    case #selector(NSResponder.cancelOperation(_:)): goBack()
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
    selectedIndex = displayPages.prefix(target).reduce(0) { $0 + $1.count }
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
    heading = title
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
    let grid = LaunchpadDropView(frame: .zero)
    grid.dragToken = sessionID?.uuidString ?? ""
    grid.onDrop = { [weak self] id in self?.moveItem(id, before: nil) }
    self.grid = grid
    grid.wantsLayer = true
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
    let edit = NSButton(title: text("整理应用"), target: self, action: #selector(toggleEditing))
    edit.bezelStyle = .rounded
    editButton = edit
    let back = NSButton(title: text("返回"), target: self, action: #selector(closeFolder))
    back.bezelStyle = .rounded
    backButton = back
    let rename = NSButton(title: text("重命名"), target: self, action: #selector(renameFolder))
    rename.bezelStyle = .rounded
    renameButton = rename
    let actions = NSStackView(views: [favorite, edit, rename])
    let footer = NSStackView(views: [pager, actions])
    footer.orientation = .vertical
    footer.spacing = DS.Space.s8
    footer.userInterfaceLayoutDirection = background.userInterfaceLayoutDirection

    for view in [title, field, close, grid, status, footer] {
      view.translatesAutoresizingMaskIntoConstraints = false
      background.addSubview(view)
    }
    for side in [-1, 1] {
      let delta = isRTL ? -side : side
      let zone = LaunchpadDropView(frame: .zero)
      zone.dragToken = sessionID?.uuidString ?? ""
      zone.onHover = { [weak self] in
        guard let self, self.folderID == nil else { return false }
        let previous = self.page
        self.changePage(by: delta)
        return self.page != previous
      }
      zone.onDrop = { [weak self, weak zone] id in
        guard let self, self.field?.stringValue.isEmpty == true else { return }
        let sourcePage =
          self.folderID.flatMap { folder in
            self.layout.pages.firstIndex(where: { $0.contains { $0.id == folder } })
          } ?? self.page
        let target = min(
          self.layout.pages.count, max(0, sourcePage + (zone?.didNavigate == true ? 0 : delta)))
        self.folderID = nil
        self.layout.move(id, toPage: target, before: nil, capacity: self.pageSize)
        self.saveLayout()
      }
      zone.translatesAutoresizingMaskIntoConstraints = false
      background.addSubview(zone)
      dragZones.append(zone)
      NSLayoutConstraint.activate([
        zone.widthAnchor.constraint(equalToConstant: 32),
        zone.topAnchor.constraint(equalTo: grid.topAnchor),
        zone.bottomAnchor.constraint(equalTo: grid.bottomAnchor),
        side < 0
          ? zone.leadingAnchor.constraint(equalTo: background.leadingAnchor)
          : zone.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      ])
    }
    let folderExit = LaunchpadDropView(frame: .zero)
    folderExit.identifier = NSUserInterfaceItemIdentifier("launchpad.folderExit")
    folderExit.dragToken = sessionID?.uuidString ?? ""
    folderExit.onDrop = { [weak self] id in
      guard let self, let folderID = self.folderID,
        let sourcePage = self.layout.pages.firstIndex(where: { $0.contains { $0.id == folderID } })
      else { return }
      self.layout.move(id, toPage: sourcePage, before: folderID, capacity: self.pageSize)
      self.folderID = nil
      self.saveLayout()
    }
    folderExit.translatesAutoresizingMaskIntoConstraints = false
    back.translatesAutoresizingMaskIntoConstraints = false
    folderExit.addSubview(back)
    background.addSubview(folderExit)
    dragZones.append(folderExit)
    NSLayoutConstraint.activate([
      folderExit.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
      folderExit.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
      folderExit.topAnchor.constraint(equalTo: grid.bottomAnchor),
      folderExit.heightAnchor.constraint(equalToConstant: 32),
      back.centerXAnchor.constraint(equalTo: folderExit.centerXAnchor),
      back.centerYAnchor.constraint(equalTo: folderExit.centerYAnchor),
    ])
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
    let query = field?.stringValue ?? ""
    if !query.isEmpty {
      results = search.results(for: query, favorites: usage?.favorites ?? [])
      displayPages = LaunchpadLayout.paginate(results, capacity: pageSize)
    } else if let folderID, let folder = layout.item(folderID) {
      results = folder.apps.compactMap { applicationMap[$0] }
      displayPages = LaunchpadLayout.paginate(results, capacity: pageSize)
    } else {
      folderID = nil
      displayPages = layout.pages.map { page in
        page.compactMap { item in
          if !item.isFolder { return applicationMap[item.id] }
          return AppCommand(
            id: item.id, title: item.name?.isEmpty == false ? item.name! : text("文件夹"),
            symbol: "folder", keywords: "", action: .launchpad)
        }
      }.filter { !$0.isEmpty }
      results = displayPages.flatMap { $0 }
    }
    selectedIndex = preservingSelection ? results.firstIndex { $0.id == selectedID } ?? 0 : 0
    status?.stringValue = text("没有匹配的项目")
    status?.isHidden = !results.isEmpty
    renderPage()
  }

  private func renderPage() {
    grid?.subviews.forEach { $0.removeFromSuperview() }
    buttons = []
    guard let grid else { return }
    grid.layer?.cornerRadius = DS.Radius.lg
    grid.layer?.backgroundColor =
      folderID == nil ? nil : NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor
    dragZones.forEach { $0.isHidden = field?.stringValue.isEmpty != true }
    dragZones.last?.isHidden = folderID == nil || field?.stringValue.isEmpty != true
    grid.layoutSubtreeIfNeeded()
    // 图标仅随当前页的按钮存活，不保留所有页面的原始 NSImage。
    let start = displayPages.prefix(page).reduce(0) { $0 + $1.count }
    let count = displayPages.indices.contains(page) ? displayPages[page].count : 0
    for index in start..<(start + count) {
      let command = results[index]
      let offset = index - start
      let column = isRTL ? columns - 1 - offset % columns : offset % columns
      let button = LaunchpadTileButton(
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
      if case .openApplication(let url) = command.action {
        button.image = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
      } else {
        button.image = folderImage(command.id)
      }
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
      button.itemID = command.id
      button.dragToken = sessionID?.uuidString ?? ""
      button.canDrag = field?.stringValue.isEmpty == true
      button.onHold = { [weak self] in self?.setEditing(true) }
      button.onDrop = { [weak self] id, group in
        guard let self else { return }
        if group && self.folderID == nil {
          self.layout.group(id, into: command.id, name: "")
          self.saveLayout()
        } else {
          self.moveItem(id, before: command.id)
        }
      }
      grid.addSubview(button)
      buttons.append(button)
      if isEditing {
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
          let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
          wobble.values = [-0.018, 0.018, -0.018]
          wobble.duration = 0.24
          // 限时抖动，避免编辑模式长期挂着时持续驱动动画。
          wobble.repeatDuration = 10
          button.layer?.add(wobble, forKey: "editing")
        }
        if candidates.contains(command.id) {
          let remove = NSButton(
            image: NSImage(
              systemSymbolName: "xmark.circle.fill", accessibilityDescription: text("移到废纸篓"))!,
            target: self, action: #selector(confirmRemoval(_:)))
          remove.frame = NSRect(
            x: button.frame.minX + 8, y: button.frame.maxY - 25, width: 24, height: 24)
          remove.tag = index
          remove.isBordered = false
          remove.setAccessibilityLabel(text("移到废纸篓 \(command.title)"))
          grid.addSubview(remove)
        }
      }
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
    let shortcut = "⌘D"
    favoriteButton?.title = text(favorite ? "取消收藏 \(shortcut)" : "收藏 \(shortcut)")
    favoriteButton?.isEnabled =
      selected != nil && selected?.id.hasPrefix("folder.") != true
      && usage != nil && (favorite || (usage?.favorites.count ?? 0) < 8)
    favoriteButton?.toolTip = text("最多收藏 8 项")
    pageLabel?.stringValue =
      "\( (page + 1).formatted(.number.locale(L10n.locale(for: language)))) / \(pageCount.formatted(.number.locale(L10n.locale(for: language))))"
    previousButton?.isEnabled = page > 0
    nextButton?.isEnabled = page + 1 < pageCount
    editButton?.title = text(isEditing ? "完成" : "整理应用")
    backButton?.isHidden = folderID == nil
    renameButton?.isHidden = folderID == nil
    // 默认文件夹名不落盘，展示时按当前语言翻译；旧数据中已存的名字原样显示。
    heading?.stringValue =
      folderID.flatMap { layout.item($0)?.name }.flatMap { $0.isEmpty ? nil : $0 }
      ?? (folderID == nil ? text("启动台") : text("文件夹"))
  }

  private func folderImage(_ id: String) -> NSImage {
    let icons = (layout.item(id)?.apps ?? []).prefix(4).compactMap { id -> NSImage? in
      guard let command = applicationMap[id], case .openApplication(let url) = command.action else {
        return nil
      }
      return NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
    }
    return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
      NSColor.controlColor.withAlphaComponent(0.8).setFill()
      NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()
      for (index, image) in icons.enumerated() {
        image.draw(in: NSRect(x: 9 + index % 2 * 25, y: 34 - index / 2 * 25, width: 21, height: 21))
      }
      return true
    }
  }

  @objc private func previousPage() { changePage(by: -1) }
  @objc private func nextPage() { changePage(by: 1) }

  @objc private func toggleFavorite() {
    guard results.indices.contains(selectedIndex),
      layout.item(results[selectedIndex].id)?.isFolder != true,
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
    if layout.item(command.id)?.isFolder == true {
      folderID = command.id
      field?.stringValue = ""
      refreshResults()
      panel?.makeFirstResponder(field)
      return
    }
    guard !isEditing else { return }
    dismiss()
    onSelect(command)
  }

  func moveItem(_ id: String, before target: String?) {
    guard field?.stringValue.isEmpty == true else { return }
    if let folderID, let folder = layout.item(folderID), folder.apps.contains(id) {
      var apps = folder.apps
      apps.removeAll { $0 == id }
      apps.insert(id, at: target.flatMap { apps.firstIndex(of: $0) } ?? apps.count)
      for page in layout.pages.indices {
        if let index = layout.pages[page].firstIndex(where: { $0.id == folderID }) {
          layout.pages[page][index].apps = apps
        }
      }
    } else {
      layout.move(id, toPage: page, before: target, capacity: pageSize)
    }
    saveLayout()
  }

  private func saveLayout() {
    layoutStore?.save(layout)
    refreshResults(preservingSelection: true)
  }

  @objc private func toggleEditing() { setEditing(!isEditing) }

  func setEditing(_ value: Bool) {
    guard isEditing != value else { return }
    isEditing = value
    renderPage()
  }

  @objc private func closeFolder() {
    folderID = nil
    field?.stringValue = ""
    refreshResults()
    panel?.makeFirstResponder(field)
  }

  private func goBack() {
    if field?.stringValue.isEmpty == false {
      field?.stringValue = ""
      refreshResults()
    } else if isEditing {
      setEditing(false)
    } else if folderID != nil {
      closeFolder()
    } else {
      dismiss()
    }
  }

  @objc private func renameFolder() {
    guard let folderID, let folder = layout.item(folderID), let panel else { return }
    let alert = NSAlert()
    alert.messageText = text("重命名")
    let input = NSTextField(string: folder.name ?? "")
    input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = input
    alert.addButton(withTitle: text("保存"))
    alert.addButton(withTitle: text("取消"))
    let session = sessionID
    alert.beginSheetModal(for: panel) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self, self.sessionID == session else { return }
      self.layout.rename(folderID, to: input.stringValue)
      self.saveLayout()
    }
  }

  @objc private func confirmRemoval(_ sender: NSButton) {
    guard results.indices.contains(sender.tag), let panel, removalTask == nil else { return }
    let command = results[sender.tag]
    guard case .openApplication(let url) = command.action, candidates.contains(command.id) else {
      return
    }
    let alert = NSAlert()
    alert.messageText = text("移到废纸篓 — \(command.title)")
    alert.informativeText = text("仅移除应用，保留文稿和个人数据。")
    alert.addButton(withTitle: text("取消"))
    alert.addButton(withTitle: text("移到废纸篓"))
    pendingDeletion = true
    let confirmationSession = sessionID
    alert.beginSheetModal(for: panel) { [weak self] response in
      guard let self, self.sessionID == confirmationSession else { return }
      self.pendingDeletion = false
      guard response == .alertSecondButtonReturn else { return }
      guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL == url }) else {
        self.showRemovalError()
        return
      }
      let session = self.sessionID
      self.removalTask = Task { [weak self] in
        let worker = Task.detached(priority: .userInitiated) {
          try LaunchpadApplicationRemoval.trash(url)
        }
        do {
          try await withTaskCancellationHandler {
            try await worker.value
          } onCancel: {
            worker.cancel()
          }
          guard !Task.isCancelled, let self, self.sessionID == session else { return }
          self.removalTask = nil
          self.layout.remove(command.id)
          self.applicationMap.removeValue(forKey: command.id)
          // 沿用现有索引仅剔除被删项，避免在主线程重建拼音索引。
          self.search = self.search?.removing(command.id)
          self.saveLayout()
          Logger(subsystem: Log.subsystem, category: "Launchpad").info("Application moved to Trash")
        } catch {
          guard !Task.isCancelled, let self, self.sessionID == session else { return }
          self.removalTask = nil
          self.showRemovalError()
        }
      }
    }
  }

  private func showRemovalError() {
    guard let panel else { return }
    Logger(subsystem: Log.subsystem, category: "Launchpad").error("Application removal failed")
    let alert = NSAlert()
    alert.messageText = text("无法移除应用")
    alert.informativeText = text("请先退出应用，并检查安装来源和访问权限。")
    alert.addButton(withTitle: text("确定"))
    alert.beginSheetModal(for: panel)
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
    let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
    scrollAmount += horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
    guard abs(scrollAmount) >= (event.hasPreciseScrollingDeltas ? 50 : 2),
      event.timestamp - lastPageTime > 0.3
    else { return }
    onPage(scrollAmount < 0 ? 1 : -1)
    scrollAmount = 0
    lastPageTime = event.timestamp
  }
}
