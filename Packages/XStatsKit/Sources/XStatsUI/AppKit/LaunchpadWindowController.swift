// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import OSLog
import QuartzCore

/// 分页限制当前控件数量；应用清单和图标由有界共享缓存按需提供。
@MainActor
final class LaunchpadWindowController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
  private(set) var panel: NSPanel?
  private(set) var results: [AppCommand] = []
  private(set) var selectedIndex = 0
  private(set) var columns = 1
  private(set) var pageSize = 1
  private(set) var browsingMode: LaunchpadBrowsingMode
  private(set) var gridLayout: LaunchpadGridLayout
  private(set) var gridIconSize: LaunchpadIconSize
  private var gridColumns = 1
  private var gridCapacity = 1
  private var listCapacity = 1
  private var pageCategories: [LaunchpadApplicationCategory?] = []
  private var modeButton: NSPopUpButton?
  private var gridLayoutButton: NSPopUpButton?
  private var search: CommandBarSearch?
  private var field: NSSearchField?
  private var grid: NSView?
  private var cellSize = NSSize(width: 132, height: 132)
  private var gridSize = NSSize.zero
  private var gridWidthConstraint: NSLayoutConstraint?
  private var gridHeightConstraint: NSLayoutConstraint?
  private var gridTopConstraint: NSLayoutConstraint?
  private var gridCenterConstraint: NSLayoutConstraint?
  private var listSurface: NSBox?
  private var headerTopConstraint: NSLayoutConstraint?
  private var searchWidthConstraint: NSLayoutConstraint?
  private var searchHeightConstraint: NSLayoutConstraint?
  private var footer: NSStackView?
  private var footerBottomConstraint: NSLayoutConstraint?
  private var footerTopConstraint: NSLayoutConstraint?
  private var footerWidthConstraint: NSLayoutConstraint?
  private var iconSize: CGFloat = 64
  private var pager: NSStackView?
  private var pageDots: NSStackView?
  private var folderBackdrop: LaunchpadFolderBackdrop?
  private var folderSurface: NSView?
  private var folderTitle: NSTextField?
  private var parentFolderID: String?
  private var pagePreview: LaunchpadPagePreview?
  private var pageSwipe = LaunchpadPageSwipe()
  private var swipePage = 0
  private var pageSettleTask: Task<Void, Never>?
  private var folderAnchor = NSPoint(x: 0.5, y: 0.5)
  private var folderExitPreview: NSView?
  private var folderExitTask: Task<Void, Never>?
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
  private var heading: NSTextField?
  private var candidates = Set<String>()
  private var pendingDeletion = false
  private var revealAnimationID: UUID?
  private var revealTimeoutTask: Task<Void, Never>?
  private var lastRevealUpdate = ContinuousClock.now
  private var dragZones: [LaunchpadDropView] = []
  private var sessionID: UUID?
  private var catalogRequestID: UUID?
  private var applicationLoader: (@Sendable () throws -> [AppCommand])?
  private var language: AppLanguage = .system
  private let usage: CommandBarUsage?
  private let layoutStore: LaunchpadLayoutStore?
  private let defaults: UserDefaults
  private let applicationRemover: @Sendable (URL) throws -> Void
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
  private var currentLayoutPage: Int? {
    if let folderID {
      return layout.pages.firstIndex { $0.contains { $0.id == folderID } }
    }
    return displayPages.indices.contains(page) ? page : nil
  }

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

  init(
    usage: CommandBarUsage? = nil, layoutStore: LaunchpadLayoutStore? = nil,
    defaults: UserDefaults = .standard,
    applicationRemover: @escaping @Sendable (URL) throws -> Void = {
      try LaunchpadApplicationRemoval.trash($0)
    }
  ) {
    self.usage = usage
    self.layoutStore = layoutStore
    self.defaults = defaults
    self.applicationRemover = applicationRemover
    browsingMode =
      defaults.string(forKey: LaunchpadBrowsingMode.preferenceKey)
      .flatMap(LaunchpadBrowsingMode.init(rawValue:)) ?? .grid
    gridLayout =
      defaults.string(forKey: LaunchpadGridLayout.preferenceKey)
      .flatMap(LaunchpadGridLayout.init(rawValue:)) ?? .automatic
    gridIconSize =
      defaults.string(forKey: LaunchpadIconSize.preferenceKey)
      .flatMap(LaunchpadIconSize.init(rawValue:)) ?? .small
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
    self.applicationLoader = applicationLoader
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
    panel.onSwipe = { [weak self] event in self?.handlePageSwipe(event) }
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
    // 注入加载器用于隔离测试，不订阅也不触碰共享目录缓存。
    if applicationLoader == nil {
      _ = LauncherApplicationCatalog.shared
      NotificationCenter.default.addObserver(
        self, selector: #selector(applicationsChanged), name: .launcherApplicationsChanged,
        object: nil)
    }
    reloadApplications()
  }

  @objc private func applicationsChanged() { reloadApplications() }

  func reloadApplications() {
    guard let session = sessionID else { return }
    catalogTask?.cancel()
    let request = UUID()
    catalogRequestID = request
    let applicationLoader = applicationLoader
    let savedLayout = search == nil ? layoutStore?.load() : layout
    let importsSystemLayout = layoutStore != nil && savedLayout == nil
    catalogTask = Task { [weak self] in
      do {
        let snapshot: LauncherApplicationSnapshot?
        if applicationLoader == nil {
          snapshot = try await LauncherApplicationCatalog.shared.load()
        } else {
          snapshot = nil
        }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
          let scanned: (commands: [AppCommand], isTruncated: Bool)
          if let applicationLoader {
            let commands = try applicationLoader()
            scanned = (commands, commands.count >= CommandBarApplications.maxApplications)
          } else {
            scanned = (snapshot?.commands ?? [], snapshot?.isTruncated ?? false)
          }
          try Task.checkCancellation()
          let applications = scanned.commands.filter {
            if case .openApplication = $0.action { return true }
            return false
          }
          let imported =
            importsSystemLayout
            ? try? LaunchpadImport.systemLayout(applications: applications) : nil
          let candidates = Set(
            applications.compactMap { command -> String? in
              guard !Task.isCancelled, case .openApplication(let url) = command.action,
                LaunchpadApplicationRemoval.isCandidate(url)
              else { return nil }
              return command.id
            })
          try Task.checkCancellation()
          return (
            CommandBarSearch(commands: applications, supportsParameterQueries: false),
            applications, imported, candidates, scanned.isTruncated
          )
        }
        let (index, applications, imported, candidates, isTruncated) =
          try await withTaskCancellationHandler {
            try await worker.value
          } onCancel: {
            worker.cancel()
          }
        guard !Task.isCancelled, let self, self.sessionID == session,
          self.catalogRequestID == request
        else { return }
        self.catalogTask = nil
        let isInitialLoad = self.search == nil
        self.search = index
        self.applicationMap = Dictionary(
          applications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.candidates = candidates
        if importsSystemLayout {
          Logger(subsystem: Log.subsystem, category: "Launchpad").info(
            "Initial layout loaded; system layout available: \(imported != nil)")
        }
        // 刷新期间仍可整理；完成时基于当前布局合并，不能用任务启动时的快照覆盖。
        if isInitialLoad { self.layout = savedLayout ?? imported ?? LaunchpadLayout() }
        // 扫描触顶时缺失不等于已卸载：保留已有布局项，也不落盘，避免永久丢失用户整理结果。
        self.layout.reconcile(
          appIDs: index.results(for: "", favorites: self.usage?.favorites ?? []).map(\.id),
          capacity: self.gridCapacity, pruneMissing: !isTruncated,
          preservingPageBoundaries: true)
        if !applications.isEmpty && !isTruncated { self.layoutStore?.save(self.layout) }
        if let folderID = self.folderID, self.layout.item(folderID)?.isFolder != true {
          self.folderID = nil
        }
        self.refreshResults(preservingSelection: true)
      } catch {
        guard !Task.isCancelled, let self, self.sessionID == session,
          self.catalogRequestID == request
        else { return }
        self.catalogTask = nil
        self.status?.stringValue = self.text("无法读取应用，请关闭后重试。")
        Logger(subsystem: Log.subsystem, category: "Launchpad").error("Application catalog failed")
        return
      }
    }
  }

  @objc func dismiss() {
    cancelPageSwipe()
    folderExitTask?.cancel()
    folderExitTask = nil
    folderExitPreview?.removeFromSuperview()
    folderExitPreview = nil
    sessionID = nil
    isRevealing = false
    revealAnimationID = nil
    revealTimeoutTask?.cancel()
    revealTimeoutTask = nil
    catalogTask?.cancel()
    catalogTask = nil
    catalogRequestID = nil
    applicationLoader = nil
    wallpaperTask?.cancel()
    wallpaperTask = nil
    removalTask?.cancel()
    removalTask = nil
    NotificationCenter.default.removeObserver(
      self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    NotificationCenter.default.removeObserver(
      self, name: .launcherApplicationsChanged, object: nil)
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
    gridWidthConstraint = nil
    gridHeightConstraint = nil
    gridTopConstraint = nil
    gridCenterConstraint = nil
    listSurface = nil
    headerTopConstraint = nil
    searchWidthConstraint = nil
    searchHeightConstraint = nil
    footer = nil
    footerBottomConstraint = nil
    footerTopConstraint = nil
    footerWidthConstraint = nil
    pager = nil
    pageDots = nil
    folderBackdrop = nil
    folderSurface = nil
    folderTitle = nil
    parentFolderID = nil
    status = nil
    pageLabel = nil
    favoriteButton = nil
    previousButton = nil
    nextButton = nil
    buttons = []
    displayPages = []
    pageCategories = []
    modeButton = nil
    gridLayoutButton = nil
    applicationMap = [:]
    layout = LaunchpadLayout()
    folderID = nil
    isEditing = false
    candidates = []
    editButton = nil
    backButton = nil
    heading = nil
    pendingDeletion = false
    dragZones = []
  }

  func windowWillClose(_ notification: Notification) { dismiss() }
  func windowDidResignKey(_ notification: Notification) {
    if panel?.attachedSheet == nil && !pendingDeletion { dismiss() }
  }

  func controlTextDidChange(_ notification: Notification) {
    if let control = notification.object as? NSControl, control !== field { return }
    refreshResults()
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let input = notification.object as? NSTextField, input === folderTitle,
      let folderID
    else { return }
    layout.rename(folderID, to: input.stringValue)
    input.stringValue =
      (layout.item(folderID)?.name).flatMap { $0.isEmpty ? nil : $0 } ?? text("文件夹")
    saveLayout()
  }

  @objc private func displayOptionsChanged() {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
      wallpaperTask?.cancel()
      wallpaperTask = nil
      panel?.contentView?.subviews.filter {
        $0.identifier?.rawValue == "launchpad.wallpaper"
      }.forEach { $0.removeFromSuperview() }
    }
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      panel?.alphaValue = 1
      grid?.layer?.setAffineTransform(.identity)
      folderExitTask?.cancel()
      folderExitTask = nil
      folderExitPreview?.removeFromSuperview()
      folderExitPreview = nil
    }
    renderPage()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard !textView.hasMarkedText() else { return false }
    if control === folderTitle {
      if selector == #selector(NSResponder.cancelOperation(_:)) {
        folderTitle?.stringValue = folderID.flatMap { layout.item($0)?.name } ?? ""
        panel?.makeFirstResponder(field)
        return true
      }
      if selector == #selector(NSResponder.insertNewline(_:)) {
        panel?.makeFirstResponder(field)
        return true
      }
      return false
    }
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
    cancelPageSwipe()
    guard !results.isEmpty else { return }
    let previousPage = page
    selectedIndex = min(max(0, selectedIndex + delta), results.count - 1)
    if previousPage != page { renderPage() } else { updateSelection() }
  }

  func changePage(by delta: Int) {
    cancelPageSwipe()
    guard !results.isEmpty else { return }
    let target = min(max(0, page + delta), pageCount - 1)
    guard target != page else { return }
    selectedIndex = displayPages.prefix(target).reduce(0) { $0 + $1.count }
    renderPage()
    panel?.makeFirstResponder(field)
  }

  private var isRTL: Bool { language.resolved.isRightToLeft }
  private func text(_ key: String) -> String { L10n.translate(key, language: language) }

  @objc private func changeBrowsingMode(_ sender: NSPopUpButton) {
    guard LaunchpadBrowsingMode.allCases.indices.contains(sender.indexOfSelectedItem) else {
      return
    }
    setBrowsingMode(LaunchpadBrowsingMode.allCases[sender.indexOfSelectedItem])
  }

  func setBrowsingMode(_ mode: LaunchpadBrowsingMode) {
    guard mode != browsingMode else { return }
    panel?.makeFirstResponder(field)
    browsingMode = mode
    defaults.set(mode.rawValue, forKey: LaunchpadBrowsingMode.preferenceKey)
    isEditing = false
    folderID = nil
    if let size = panel?.contentView?.bounds.size { updateGridGeometry(size: size) }
    columns = mode == .list ? 1 : gridColumns
    pageSize = mode == .list ? listCapacity : gridCapacity
    modeButton?.selectItem(at: LaunchpadBrowsingMode.allCases.firstIndex(of: mode) ?? 0)
    if mode == .grid {
      grid?.registerForDraggedTypes([LaunchpadTileButton.pasteboardType])
    } else {
      grid?.unregisterDraggedTypes()
    }
    refreshResults(preservingSelection: true)
    panel?.makeFirstResponder(field)
  }

  @objc private func refreshApplications() {
    if applicationLoader == nil {
      NotificationCenter.default.post(name: .launcherApplicationsChanged, object: nil)
    } else {
      reloadApplications()
    }
    panel?.makeFirstResponder(field)
  }

  @objc private func changeGridLayout(_ sender: NSMenuItem) {
    guard LaunchpadGridLayout.allCases.indices.contains(sender.tag) else { return }
    setGridLayout(LaunchpadGridLayout.allCases[sender.tag])
  }

  func setGridLayout(_ value: LaunchpadGridLayout) {
    guard value != gridLayout else { return }
    panel?.makeFirstResponder(field)
    gridLayout = value
    defaults.set(value.rawValue, forKey: LaunchpadGridLayout.preferenceKey)
    folderID = nil
    isEditing = false
    if let size = panel?.contentView?.bounds.size { updateGridGeometry(size: size) }
    refreshResults(preservingSelection: true)
  }

  @objc private func changeIconSize(_ sender: NSMenuItem) {
    guard LaunchpadIconSize.allCases.indices.contains(sender.tag) else { return }
    setIconSize(LaunchpadIconSize.allCases[sender.tag])
  }

  func setIconSize(_ value: LaunchpadIconSize) {
    guard value != gridIconSize else { return }
    panel?.makeFirstResponder(field)
    gridIconSize = value
    defaults.set(value.rawValue, forKey: LaunchpadIconSize.preferenceKey)
    if let size = panel?.contentView?.bounds.size { updateGridGeometry(size: size) }
    refreshResults(preservingSelection: true)
  }

  private func updateGridGeometry(size: NSSize) {
    let availableColumns = max(1, min(8, Int((size.width - 64) / 132)))
    let availableRows = max(1, min(6, Int((size.height - 240) / 132)))
    gridColumns = min(gridLayout.maximumColumns, availableColumns)
    let rows = min(gridLayout.maximumRows, availableRows)
    gridCapacity = gridColumns * rows
    listCapacity = max(1, min(12, Int((size.height - 224) / DS.Space.s12)))
    var gridWidth = min(size.width - 64, max(CGFloat(gridColumns) * 132, size.width * 0.8))
    var gridHeight = max(
      CGFloat(browsingMode == .list ? availableRows : rows) * 132, (size.height - 240) * 0.88)
    if browsingMode != .list {
      let preferredCellSide = max(132, gridIconSize.points + DS.Space.s16)
      gridWidth = min(gridWidth, CGFloat(gridColumns) * preferredCellSide)
      gridHeight = min(gridHeight, CGFloat(rows) * preferredCellSide)
    } else {
      gridWidth = min(480, size.width - 112)
      gridHeight = CGFloat(listCapacity) * DS.Space.s12
    }
    gridSize = NSSize(width: gridWidth, height: gridHeight)
    cellSize = NSSize(width: gridWidth / CGFloat(gridColumns), height: gridHeight / CGFloat(rows))
    iconSize = min(gridIconSize.points, max(48, min(cellSize.width - 40, cellSize.height - 48)))
    columns = browsingMode == .list ? 1 : gridColumns
    pageSize = browsingMode == .list ? listCapacity : gridCapacity
  }

  private func buildContent(size: NSSize) {
    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    background.material = .fullScreenUI
    background.blendingMode = .behindWindow
    background.state = .active
    background.appearance = NSAppearance(named: .darkAqua)
    background.userInterfaceLayoutDirection = isRTL ? .rightToLeft : .leftToRight
    panel?.contentView = background

    let field = NSSearchField()
    field.placeholderString = text("搜索应用")
    field.setAccessibilityLabel(field.placeholderString)
    field.controlSize = .large
    field.font = .systemFont(ofSize: DS.TextSize.sm.rawValue)
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
    title.lineBreakMode = .byTruncatingTail
    title.alignment = isRTL ? .right : .left
    title.identifier = NSUserInterfaceItemIdentifier("launchpad.heading")
    title.setContentHuggingPriority(.defaultLow, for: .horizontal)
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let modes = NSPopUpButton(frame: .zero, pullsDown: false)
    modes.addItems(withTitles: LaunchpadBrowsingMode.allCases.map { text($0.titleKey) })
    modes.selectItem(at: LaunchpadBrowsingMode.allCases.firstIndex(of: browsingMode) ?? 0)
    modes.target = self
    modes.action = #selector(changeBrowsingMode(_:))
    modes.identifier = NSUserInterfaceItemIdentifier("launchpad.browsingMode")
    modes.setAccessibilityLabel(text("浏览方式"))
    modes.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    modes.userInterfaceLayoutDirection = background.userInterfaceLayoutDirection
    modeButton = modes
    let gridLayouts = NSPopUpButton(frame: .zero, pullsDown: true)
    gridLayouts.addItem(withTitle: "")
    gridLayouts.item(at: 0)?.image = NSImage(
      systemSymbolName: "square.grid.3x3", accessibilityDescription: text("网格布局"))
    gridLayouts.imagePosition = .imageOnly
    gridLayouts.identifier = NSUserInterfaceItemIdentifier("launchpad.gridLayout")
    gridLayouts.setAccessibilityLabel(text("网格布局"))
    gridLayouts.userInterfaceLayoutDirection = background.userInterfaceLayoutDirection
    for (index, value) in LaunchpadGridLayout.allCases.enumerated() {
      let item = NSMenuItem(
        title: value == .automatic ? text(value.titleKey) : "\u{2066}\(value.titleKey)\u{2069}",
        action: #selector(changeGridLayout(_:)), keyEquivalent: "")
      item.tag = index
      item.target = self
      gridLayouts.menu?.addItem(item)
    }
    gridLayouts.menu?.addItem(.separator())
    for (index, value) in LaunchpadIconSize.allCases.enumerated() {
      let item = NSMenuItem(
        title: text(value.titleKey), action: #selector(changeIconSize(_:)), keyEquivalent: "")
      item.tag = index
      item.target = self
      gridLayouts.menu?.addItem(item)
    }
    gridLayoutButton = gridLayouts
    let refresh = NSButton(
      image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: text("刷新"))!,
      target: self, action: #selector(refreshApplications))
    refresh.bezelStyle = .circular
    refresh.setAccessibilityLabel(text("刷新"))
    refresh.toolTip = text("刷新")
    refresh.identifier = NSUserInterfaceItemIdentifier("launchpad.refresh")
    let header = NSStackView(views: [title, modes, gridLayouts, refresh])
    header.spacing = DS.Space.s2
    header.distribution = .fill
    header.alignment = .centerY
    header.userInterfaceLayoutDirection = background.userInterfaceLayoutDirection
    let close = NSButton(
      image: NSImage(systemSymbolName: "xmark", accessibilityDescription: text("关闭"))!,
      target: self, action: #selector(dismiss))
    close.bezelStyle = .circular
    close.setAccessibilityLabel(text("关闭"))
    close.toolTip = text("关闭") + " (Esc)"
    close.keyEquivalent = "w"
    close.keyEquivalentModifierMask = .command

    updateGridGeometry(size: size)
    let grid = LaunchpadDropView(frame: .zero)
    grid.identifier = NSUserInterfaceItemIdentifier("launchpad.grid")
    grid.dragToken = sessionID?.uuidString ?? ""
    grid.onDrop = { [weak self] id in self?.moveItem(id, before: nil) }
    if browsingMode != .grid { grid.unregisterDraggedTypes() }
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
    let dots = NSStackView()
    dots.spacing = DS.Space.s1
    pageDots = dots
    let pager = NSStackView(views: [previous, dots, pageLabel, next])
    self.pager = pager
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
    let actions = NSStackView(views: [favorite, edit])
    let footer = NSStackView(views: [pager, actions])
    self.footer = footer
    footer.orientation = .vertical
    footer.spacing = DS.Space.s8
    footer.userInterfaceLayoutDirection = background.userInterfaceLayoutDirection

    for view in [header, field, close, grid, status, footer] {
      view.translatesAutoresizingMaskIntoConstraints = false
      background.addSubview(view)
    }
    let surface = NSBox()
    surface.boxType = .custom
    surface.titlePosition = .noTitle
    surface.borderWidth = 0
    surface.cornerRadius = DS.Radius.xl
    surface.identifier = NSUserInterfaceItemIdentifier("launchpad.listSurface")
    surface.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(surface, positioned: .below, relativeTo: header)
    listSurface = surface
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: -DS.Space.s6),
      surface.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: DS.Space.s6),
      surface.topAnchor.constraint(equalTo: header.topAnchor, constant: -DS.Space.s6),
      surface.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: DS.Space.s6),
    ])
    for side in [-1, 1] {
      let delta = isRTL ? -side : side
      let zone = LaunchpadDropView(frame: .zero)
      zone.identifier = NSUserInterfaceItemIdentifier(
        delta < 0 ? "launchpad.page.previous" : "launchpad.page.next")
      zone.dragToken = sessionID?.uuidString ?? ""
      zone.onHover = { [weak self] in
        guard let self, self.browsingMode == .grid, self.folderID == nil else { return false }
        let previous = self.page
        self.changePage(by: delta)
        return self.page != previous
      }
      zone.onDrop = { [weak self, weak zone] id in
        self?.moveItem(id, toAdjacentPage: delta, afterHover: zone?.didNavigate == true)
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
      guard let self, self.browsingMode == .grid, let folderID = self.folderID else { return }
      self.materializeGridPages()
      guard
        let sourcePage = self.layout.pages.firstIndex(where: { $0.contains { $0.id == folderID } })
      else { return }
      self.layout.move(id, toPage: sourcePage, before: folderID, capacity: self.gridCapacity)
      self.folderID = nil
      self.saveLayout()
    }
    folderExit.translatesAutoresizingMaskIntoConstraints = false
    back.translatesAutoresizingMaskIntoConstraints = false
    folderExit.addSubview(back)
    background.addSubview(folderExit)
    dragZones.append(folderExit)
    let width = grid.widthAnchor.constraint(equalToConstant: gridSize.width)
    let height = grid.heightAnchor.constraint(equalToConstant: gridSize.height)
    let center = grid.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: -8)
    gridWidthConstraint = width
    gridHeightConstraint = height
    gridTopConstraint = grid.topAnchor.constraint(
      equalTo: field.bottomAnchor, constant: DS.Space.s4)
    gridCenterConstraint = center
    let headerTop = header.topAnchor.constraint(equalTo: background.topAnchor, constant: 40)
    headerTopConstraint = headerTop
    let searchWidth = field.widthAnchor.constraint(equalToConstant: min(440, size.width - 112))
    searchWidthConstraint = searchWidth
    let searchHeight = field.heightAnchor.constraint(equalToConstant: DS.Size.controlHeight)
    searchHeightConstraint = searchHeight
    let footerBottom = footer.bottomAnchor.constraint(
      equalTo: background.bottomAnchor, constant: -44)
    footerBottomConstraint = footerBottom
    footerTopConstraint = footer.topAnchor.constraint(
      equalTo: grid.bottomAnchor, constant: DS.Space.s4)
    footerWidthConstraint = footer.widthAnchor.constraint(equalTo: field.widthAnchor)
    NSLayoutConstraint.activate([
      folderExit.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
      folderExit.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
      folderExit.topAnchor.constraint(equalTo: grid.bottomAnchor),
      folderExit.heightAnchor.constraint(equalToConstant: 32),
      back.centerXAnchor.constraint(equalTo: folderExit.centerXAnchor),
      back.centerYAnchor.constraint(equalTo: folderExit.centerYAnchor),
    ])
    NSLayoutConstraint.activate([
      header.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      headerTop,
      header.widthAnchor.constraint(equalTo: field.widthAnchor),
      header.heightAnchor.constraint(equalToConstant: 30),
      modes.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
      modes.widthAnchor.constraint(lessThanOrEqualToConstant: min(200, (size.width - 112) * 0.42)),
      gridLayouts.widthAnchor.constraint(equalToConstant: 44),
      refresh.widthAnchor.constraint(equalToConstant: 28),
      close.topAnchor.constraint(equalTo: background.topAnchor, constant: 40),
      close.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -32),
      field.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DS.Space.s4),
      field.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      searchWidth,
      searchHeight,
      grid.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      center,
      width,
      height,
      status.centerXAnchor.constraint(equalTo: grid.centerXAnchor),
      status.centerYAnchor.constraint(equalTo: grid.centerYAnchor),
      footer.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      footerBottom,
      pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
    ])
    updateSelection()
  }

  private func refreshResults(preservingSelection: Bool = false) {
    guard let search else { return }
    let selectedID = results.indices.contains(selectedIndex) ? results[selectedIndex].id : nil
    let query = field?.stringValue ?? ""
    let inFolder = browsingMode == .grid && folderID != nil && query.isEmpty
    let folderCount =
      folderID.flatMap { layout.item($0) }?.apps.filter {
        applicationMap[$0] != nil
      }.count ?? 0
    columns =
      browsingMode == .list ? 1 : inFolder ? min(6, gridColumns, max(1, folderCount)) : gridColumns
    pageSize =
      browsingMode == .list
      ? listCapacity
      : inFolder ? columns * min(4, gridCapacity / gridColumns) : gridCapacity
    pageCategories = []
    if browsingMode != .grid {
      let applications =
        query.isEmpty
        ? LaunchpadBrowsing.applications(in: layout, catalog: applicationMap)
        : search.results(for: query, favorites: usage?.favorites ?? [])
      let pages = LaunchpadBrowsing.pages(
        applications: applications, mode: browsingMode, capacity: pageSize)
      displayPages = pages.map(\.commands)
      pageCategories = pages.map(\.category)
      results = displayPages.flatMap { $0 }
    } else if !query.isEmpty {
      results = search.results(for: query, favorites: usage?.favorites ?? [])
      displayPages = LaunchpadLayout.paginate(results, capacity: gridCapacity)
    } else if let folderID, let folder = layout.item(folderID) {
      results = folder.apps.compactMap { applicationMap[$0] }
      displayPages = LaunchpadLayout.paginate(results, capacity: pageSize)
    } else {
      folderID = nil
      results = layout.pages.joined().compactMap { item -> AppCommand? in
        if !item.isFolder { return applicationMap[item.id] }
        return AppCommand(
          id: item.id, title: item.name?.isEmpty == false ? item.name! : text("文件夹"),
          symbol: "folder", keywords: "", action: .launchpad)
      }
      displayPages = LaunchpadLayout.paginate(results, capacity: gridCapacity)
    }
    selectedIndex = preservingSelection ? results.firstIndex { $0.id == selectedID } ?? 0 : 0
    status?.stringValue = text("没有匹配的项目")
    status?.isHidden = !results.isEmpty
    renderPage()
  }

  private func renderPage(preservingSwipe: Bool = false) {
    if !preservingSwipe { cancelPageSwipe() }
    grid?.subviews.forEach { $0.removeFromSuperview() }
    buttons = []
    guard let grid else { return }
    let inFolder = browsingMode == .grid && folderID != nil && field?.stringValue.isEmpty == true
    let followsSearch = !inFolder
    if followsSearch {
      gridCenterConstraint?.isActive = false
      gridTopConstraint?.isActive = true
    } else {
      gridTopConstraint?.isActive = false
      gridCenterConstraint?.isActive = true
    }
    let count = displayPages.indices.contains(page) ? displayPages[page].count : 0
    let folderRows = max(1, min(pageSize / columns, (results.count + columns - 1) / columns))
    var folderHeight = gridSize.height
    if inFolder, let content = panel?.contentView, let field {
      content.layoutSubtreeIfNeeded()
      let center = content.convert(grid.bounds, from: grid).midY
      let searchBottom = content.convert(field.bounds, from: field).minY
      folderHeight = max(1, 2 * (searchBottom - DS.Space.s4 - 48 - center))
    }
    let tileSize =
      inFolder
      ? NSSize(
        width: min(cellSize.width, 160),
        height: min(cellSize.height, 160, folderHeight / CGFloat(folderRows))) : cellSize
    let tileIconSize = inFolder ? min(iconSize, max(48, tileSize.height - 48)) : iconSize
    gridWidthConstraint?.constant = inFolder ? CGFloat(columns) * tileSize.width : gridSize.width
    gridHeightConstraint?.constant =
      browsingMode == .list
      ? CGFloat(max(1, count)) * DS.Space.s12
      : inFolder ? CGFloat(folderRows) * tileSize.height : gridSize.height
    panel?.contentView?.layoutSubtreeIfNeeded()
    grid.layer?.cornerRadius = DS.Radius.lg
    grid.layer?.backgroundColor = nil
    updateFolderPresentation()
    dragZones.forEach {
      $0.isHidden = browsingMode != .grid || field?.stringValue.isEmpty != true
    }
    dragZones.last?.isHidden =
      browsingMode != .grid || folderID == nil || field?.stringValue.isEmpty != true
    grid.layoutSubtreeIfNeeded()
    // 仅为当前页创建控件，图标交由有界缓存复用。
    let start = displayPages.prefix(page).reduce(0) { $0 + $1.count }
    for index in start..<(start + count) {
      let command = results[index]
      let offset = index - start
      let column = isRTL ? columns - 1 - offset % columns : offset % columns
      let isList = browsingMode == .list
      let button = LaunchpadTileButton(
        frame: isList
          ? NSRect(
            x: 0, y: grid.bounds.height - CGFloat(offset + 1) * DS.Space.s12 + 2,
            width: grid.bounds.width, height: DS.Space.s12 - DS.Space.s1)
          : NSRect(
            x: CGFloat(column) * tileSize.width + 6,
            y: grid.bounds.height - CGFloat(offset / columns + 1) * tileSize.height + 6,
            width: tileSize.width - 12, height: tileSize.height - 12))
      if isList { button.cell = LaunchpadListButtonCell() }
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = isList ? (isRTL ? .right : .left) : .center
      paragraph.lineBreakMode = .byTruncatingTail
      button.attributedTitle = NSAttributedString(
        string: command.title,
        attributes: [
          .font: NSFont.systemFont(ofSize: DS.TextSize.sm.rawValue),
          .foregroundColor: NSColor.labelColor,
          .paragraphStyle: paragraph,
        ])
      button.imagePosition = isList ? .imageLeading : .imageAbove
      if case .openApplication(let url) = command.action {
        button.image = LauncherIconCache.shared.image(for: url, size: isList ? 28 : tileIconSize)
        if !isList {
          button.imagePosition = .imageOnly
        }
      } else {
        button.image = folderImage(command.id)
      }
      button.alignment = isList ? (isRTL ? .right : .left) : .center
      button.userInterfaceLayoutDirection = isRTL ? .rightToLeft : .leftToRight
      button.imageScaling = .scaleProportionallyDown
      button.isBordered = false
      button.lineBreakMode = .byTruncatingTail
      grid.addSubview(button)
      if !isList {
        let center = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let side = min(button.frame.width, button.frame.height, tileIconSize + DS.Space.s6)
        button.setFrameSize(
          NSSize(
            width: button.imagePosition == .imageAbove
              ? min(tileSize.width - 12, max(side, 120)) : side,
            height: side))
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        let imagePosition = grid.convert(imageRect, from: button)
        button.setFrameOrigin(
          NSPoint(
            x: button.frame.minX + center.x - imagePosition.midX,
            y: button.frame.minY + center.y - imagePosition.midY))
      }
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
      button.canDrag = browsingMode == .grid && field?.stringValue.isEmpty == true
      button.onHold = { [weak self] in self?.setEditing(true) }
      button.onDrop = { [weak self] id, group in
        guard let self, self.browsingMode == .grid, self.field?.stringValue.isEmpty == true else {
          return
        }
        if group && self.folderID == nil {
          self.layout.group(id, into: command.id, name: "")
          self.saveLayout()
        } else {
          self.moveItem(id, before: command.id)
        }
      }
      buttons.append(button)
      if isEditing && browsingMode == .grid {
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
    let isList = browsingMode == .list
    if let surface = listSurface {
      surface.isHidden = !isList
      surface.effectiveAppearance.performAsCurrentDrawingAppearance {
        surface.fillColor =
          (NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor)
          .withAlphaComponent(
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.92)
      }
    }
    if let size = panel?.contentView?.bounds.size {
      let listContentHeight =
        30 + DS.Space.s4 + 40 + DS.Space.s4 + gridSize.height
        + DS.Space.s4 + DS.Size.controlHeight
      headerTopConstraint?.constant = isList ? max(40, (size.height - listContentHeight) / 2) : 40
      searchWidthConstraint?.constant = min(isList ? 480 : 440, size.width - 112)
    }
    searchHeightConstraint?.constant = isList ? 40 : DS.Size.controlHeight
    field?.focusRingType = isList ? .none : .default
    footerBottomConstraint?.isActive = !isList
    footerTopConstraint?.isActive = isList
    footerWidthConstraint?.isActive = isList
    footer?.orientation = isList ? .horizontal : .vertical
    footer?.distribution = isList ? .equalSpacing : .fill
    footer?.spacing = isList ? DS.Space.s4 : DS.Space.s8
    for button in buttons {
      let selected = button.tag == selectedIndex
      button.layer?.backgroundColor =
        selected ? NSColor.controlAccentColor.withAlphaComponent(isList ? 0.28 : 0.15).cgColor : nil
      button.layer?.borderWidth = selected && !isList ? 2 : 0
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
    pager?.isHidden = pageCount <= 1
    updatePageDots()
    editButton?.title = text(isEditing ? "完成" : "整理应用")
    editButton?.isHidden = browsingMode != .grid
    gridLayoutButton?.isEnabled = browsingMode != .list && folderID == nil
    gridLayoutButton?.isHidden = isList
    gridLayoutButton?.toolTip =
      text("网格布局") + ": " + text(gridLayout.titleKey) + " · " + text(gridIconSize.titleKey)
    for item in gridLayoutButton?.menu?.items.dropFirst() ?? [] {
      if item.action == #selector(changeGridLayout(_:)) {
        item.state = LaunchpadGridLayout.allCases[item.tag] == gridLayout ? .on : .off
      } else if item.action == #selector(changeIconSize(_:)) {
        item.state = LaunchpadIconSize.allCases[item.tag] == gridIconSize ? .on : .off
      }
    }
    backButton?.isHidden = folderID == nil
    // 默认文件夹名不落盘，展示时按当前语言翻译；旧数据中已存的名字原样显示。
    heading?.stringValue =
      folderID.flatMap { layout.item($0)?.name }.flatMap { $0.isEmpty ? nil : $0 }
      ?? (folderID == nil ? text("启动台") : text("文件夹"))
    if pageCategories.indices.contains(page), let category = pageCategories[page] {
      heading?.stringValue = text(category.titleKey)
    }
    if folderSurface?.isHidden == false {
      if folderTitle?.currentEditor() == nil {
        folderTitle?.stringValue = heading?.stringValue ?? text("文件夹")
      }
      heading?.stringValue = text("启动台")
    }
    heading?.toolTip = heading?.stringValue
    heading?.setAccessibilityLabel(heading?.stringValue)
  }

  private func updatePageDots() {
    guard let pageDots else { return }
    pageDots.isHidden = browsingMode == .list
    let first = max(0, min(page - 3, pageCount - 7))
    let indices = Array(first..<min(pageCount, first + 7))
    if pageDots.arrangedSubviews.compactMap({ ($0 as? NSButton)?.tag }) != indices {
      pageDots.arrangedSubviews.forEach { $0.removeFromSuperview() }
      for index in indices {
        let dot = NSButton(
          image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!,
          target: self, action: #selector(selectPage(_:)))
        dot.isBordered = false
        dot.imageScaling = .scaleNone
        dot.image = dot.image?.withSymbolConfiguration(.init(pointSize: 6, weight: .regular))
        dot.tag = index
        dot.identifier = NSUserInterfaceItemIdentifier("launchpad.dot.\(index)")
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          dot.widthAnchor.constraint(equalToConstant: 20),
          dot.heightAnchor.constraint(equalToConstant: 24),
        ])
        pageDots.addArrangedSubview(dot)
      }
    }
    for case let dot as NSButton in pageDots.arrangedSubviews {
      dot.setAccessibilityLabel(
        "\((dot.tag + 1).formatted(.number.locale(L10n.locale(for: language)))) / \(pageCount.formatted(.number.locale(L10n.locale(for: language))))"
      )
      dot.contentTintColor = dot.tag == page ? .labelColor : .tertiaryLabelColor
      dot.setAccessibilityValue(dot.tag == page)
    }
    pageLabel?.isHidden = browsingMode != .list && pageCount <= 7
  }

  @objc private func selectPage(_ sender: NSButton) { changePage(by: sender.tag - page) }

  private func prepareFolderPresentation(_ id: String) {
    guard let grid, let content = panel?.contentView else { return }
    folderExitTask?.cancel()
    folderExitTask = nil
    folderExitPreview?.removeFromSuperview()
    folderExitPreview = nil
    content.layoutSubtreeIfNeeded()
    if let button = buttons.first(where: { $0.identifier?.rawValue == id }) {
      folderAnchor = NSPoint(
        x: button.frame.midX / grid.bounds.width, y: button.frame.midY / grid.bounds.height)
    }
    parentFolderID = id
    let backdrop = LaunchpadFolderBackdrop(frame: content.bounds)
    backdrop.identifier = NSUserInterfaceItemIdentifier("launchpad.folderBackdrop")
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
    if let image = LaunchpadPagePreview.snapshot(grid) {
      let parent = CALayer()
      parent.contents = image
      parent.frame = content.convert(grid.bounds, from: grid)
      parent.opacity = 0.25
      backdrop.layer?.addSublayer(parent)
    }
    backdrop.onClose = { [weak self] in self?.closeFolder() }
    content.addSubview(backdrop, positioned: .below, relativeTo: heading?.superview)
    folderBackdrop = backdrop
    let surface = NSView()
    surface.identifier = NSUserInterfaceItemIdentifier("launchpad.folderSurface")
    surface.wantsLayer = true
    surface.layer?.cornerRadius = DS.Radius.xl
    content.addSubview(surface, positioned: .below, relativeTo: grid)
    folderSurface = surface
    let title = NSTextField(string: "")
    title.identifier = NSUserInterfaceItemIdentifier("launchpad.folderTitle")
    title.font = .systemFont(ofSize: DS.TextSize.xl.rawValue, weight: .medium)
    title.alignment = .center
    title.isBordered = false
    title.drawsBackground = false
    title.focusRingType = .none
    title.delegate = self
    title.setAccessibilityLabel(text("重命名"))
    surface.addSubview(title)
    folderTitle = title
  }

  private func updateFolderPresentation() {
    guard let content = panel?.contentView, let grid else { return }
    guard browsingMode == .grid, folderID != nil else {
      folderBackdrop?.removeFromSuperview()
      folderSurface?.removeFromSuperview()
      folderBackdrop = nil
      folderSurface = nil
      folderTitle = nil
      parentFolderID = nil
      return
    }
    let searching = field?.stringValue.isEmpty != true
    folderBackdrop?.isHidden = searching
    folderSurface?.isHidden = searching
    content.layoutSubtreeIfNeeded()
    let rect = content.convert(grid.bounds, from: grid)
    folderSurface?.frame = NSRect(
      x: rect.minX - 12, y: rect.minY - 32, width: rect.width + 24, height: rect.height + 80)
    content.effectiveAppearance.performAsCurrentDrawingAppearance {
      folderSurface?.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
      folderSurface?.layer?.borderWidth =
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0
      folderSurface?.layer?.borderColor = NSColor.labelColor.cgColor
    }
    folderTitle?.frame = NSRect(x: 24, y: rect.height + 40, width: rect.width - 24, height: 30)
  }

  private func cancelPageSwipe() {
    pageSettleTask?.cancel()
    pageSettleTask = nil
    pagePreview?.removeFromSuperview()
    pagePreview = nil
    grid?.layer?.opacity = 1
    pageSwipe = LaunchpadPageSwipe()
  }

  func handlePageSwipe(_ event: NSEvent) {
    guard let grid, let content = panel?.contentView, !results.isEmpty else { return }
    let ending = event.phase.contains(.ended) || event.phase.contains(.cancelled)
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if reduceMotion {
      if !pageSwipe.isActive { swipePage = page }
      if event.scrollingDeltaX != 0 {
        pageSwipe.update(delta: event.scrollingDeltaX, timestamp: event.timestamp)
      }
      if ending {
        let target =
          event.phase.contains(.cancelled)
          ? swipePage
          : pageSwipe.destination(
            width: grid.bounds.width, page: swipePage, count: pageCount, timestamp: event.timestamp)
        changePage(by: target - page)
      }
      return
    }
    guard !ending || pagePreview != nil else { return }
    if event.phase.contains(.began) || pagePreview == nil || pageSettleTask != nil {
      panel?.makeFirstResponder(field)
      var offset: CGFloat = 0
      if let previous = pagePreview {
        let translation = previous.translation
        let anchor = min(
          pageCount - 1, max(0, swipePage - Int((translation / grid.bounds.width).rounded())))
        offset = translation + CGFloat(anchor - swipePage) * grid.bounds.width
        selectedIndex = displayPages.prefix(anchor).reduce(0) { $0 + $1.count }
      }
      cancelPageSwipe()
      swipePage = page
      var previewFrame = content.convert(grid.bounds, from: grid)
      if browsingMode == .list {
        previewFrame.origin.y = previewFrame.maxY - gridSize.height
        previewFrame.size.height = gridSize.height
      }
      let preview = LaunchpadPagePreview(frame: previewFrame)
      let selection = selectedIndex
      for target in max(0, page - 1)...min(pageCount - 1, page + 1) {
        selectedIndex = displayPages.prefix(target).reduce(0) { $0 + $1.count }
        renderPage()
        if let image = LaunchpadPagePreview.snapshot(grid) {
          preview.add(image, delta: target - swipePage, size: grid.bounds.size)
        }
      }
      selectedIndex = selection
      renderPage()
      pageSwipe = LaunchpadPageSwipe(offset: offset)
      pagePreview = preview
      content.addSubview(preview, positioned: .above, relativeTo: grid)
      grid.layer?.opacity = 0
    }
    guard let preview = pagePreview else { return }
    if event.scrollingDeltaX != 0 {
      pageSwipe.update(delta: event.scrollingDeltaX, timestamp: event.timestamp)
    }
    let offset = pageSwipe.translation(width: grid.bounds.width, page: swipePage, count: pageCount)
    preview.track(offset)
    guard ending else { return }
    let target =
      event.phase.contains(.cancelled)
      ? swipePage
      : pageSwipe.destination(
        width: grid.bounds.width, page: swipePage, count: pageCount, timestamp: event.timestamp)
    preview.settle(
      at: CGFloat(swipePage - target) * grid.bounds.width, velocity: pageSwipe.velocity)
    selectedIndex = displayPages.prefix(target).reduce(0) { $0 + $1.count }
    renderPage(preservingSwipe: true)
    let session = sessionID
    pageSettleTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(DS.Motion.launchpadResponse * 2)) } catch { return }
      guard let self, self.sessionID == session else { return }
      self.changePage(by: target - self.page)
    }
  }

  private func animateFolderEntrance() {
    guard NSApp.currentEvent?.type == .leftMouseUp,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else { return }
    for view in [grid, folderSurface].compactMap({ $0 }) {
      guard let layer = view.layer else { continue }
      let start = CGAffineTransform(
        translationX: view.bounds.width * folderAnchor.x * 0.04,
        y: view.bounds.height * folderAnchor.y * 0.04
      ).scaledBy(x: 0.96, y: 0.96)
      let grow = CABasicAnimation(keyPath: "transform")
      grow.fromValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(start))
      grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
      grow.duration = DS.Motion.selectionDuration
      grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
      layer.add(grow, forKey: "folder")
    }
  }

  private func animateFolderExit() {
    guard
      NSApp.currentEvent?.type == .leftMouseDown
        || NSApp.currentEvent?.type == .leftMouseUp,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      let grid, let surface = folderSurface, !surface.isHidden,
      let content = panel?.contentView, let image = LaunchpadPagePreview.snapshot(grid)
    else { return }
    let preview = LaunchpadFolderTransition(frame: surface.frame)
    preview.wantsLayer = true
    preview.layer?.cornerRadius = DS.Radius.xl
    surface.effectiveAppearance.performAsCurrentDrawingAppearance {
      preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
    let icons = CALayer()
    icons.frame = preview.convert(grid.bounds, from: grid)
    icons.contents = image
    preview.layer?.addSublayer(icons)
    if let title = folderTitle, let image = LaunchpadPagePreview.snapshot(title) {
      let heading = CALayer()
      heading.frame = title.frame
      heading.contents = image
      preview.layer?.addSublayer(heading)
    }
    preview.setAccessibilityElement(false)
    content.addSubview(preview)
    folderExitPreview = preview
    let shrink = CABasicAnimation(keyPath: "transform")
    shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
    shrink.toValue = NSValue(
      caTransform3D: CATransform3DMakeAffineTransform(
        CGAffineTransform(
          translationX: preview.bounds.width * folderAnchor.x * 0.04,
          y: preview.bounds.height * folderAnchor.y * 0.04
        ).scaledBy(x: 0.96, y: 0.96)))
    shrink.duration = DS.Motion.selectionDuration
    shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    fade.duration = DS.Motion.selectionDuration
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    preview.layer?.opacity = 0
    preview.layer?.add(shrink, forKey: "folder")
    preview.layer?.add(fade, forKey: "fade")
    CATransaction.commit()
    folderExitTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(DS.Motion.selectionDuration)) } catch { return }
      self?.folderExitPreview?.removeFromSuperview()
      self?.folderExitPreview = nil
      self?.folderExitTask = nil
    }
  }

  private func folderImage(_ id: String) -> NSImage {
    let icons = (layout.item(id)?.apps ?? []).prefix(4).compactMap { id -> NSImage? in
      guard let command = applicationMap[id], case .openApplication(let url) = command.action else {
        return nil
      }
      return LauncherIconCache.shared.image(for: url, size: 21 * iconSize / 64)
    }
    return NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { rect in
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      let inset = rect.width * 0.08
      let scale = (rect.width - inset * 2) / 64
      let transform = NSAffineTransform()
      transform.translateX(by: rect.minX + inset, yBy: rect.minY + inset)
      transform.scale(by: scale)
      transform.concat()
      let rect = NSRect(x: 0, y: 0, width: 64, height: 64)
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
    cancelPageSwipe()
    let index = sender?.tag ?? selectedIndex
    guard results.indices.contains(index) else { return }
    let command = results[index]
    if browsingMode == .grid && layout.item(command.id)?.isFolder == true {
      prepareFolderPresentation(command.id)
      folderID = command.id
      field?.stringValue = ""
      refreshResults()
      animateFolderEntrance()
      panel?.makeFirstResponder(field)
      return
    }
    guard !isEditing else { return }
    dismiss()
    onSelect(command)
  }

  func moveItem(_ id: String, before target: String?) {
    guard browsingMode == .grid, field?.stringValue.isEmpty == true else { return }
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
      materializeGridPages()
      guard let currentLayoutPage else { return }
      layout.move(id, toPage: currentLayoutPage, before: target, capacity: gridCapacity)
    }
    saveLayout()
  }

  func moveItem(_ id: String, toAdjacentPage delta: Int, afterHover: Bool) {
    guard browsingMode == .grid, field?.stringValue.isEmpty == true else { return }
    materializeGridPages()
    guard let currentLayoutPage else { return }
    let target = min(layout.pages.count, max(0, currentLayoutPage + (afterHover ? 0 : delta)))
    folderID = nil
    layout.move(id, toPage: target, before: nil, capacity: gridCapacity)
    saveLayout()
  }

  private func materializeGridPages() {
    let items = Array(layout.pages.joined())
    let visible = items.filter { $0.isFolder || applicationMap[$0.id] != nil }
    let unavailable = items.filter { !$0.isFolder && applicationMap[$0.id] == nil }
    // 拖动前将显示页落实到布局；扫描不完整时仍保留未读到的应用，避免误删布局。
    let pages =
      LaunchpadLayout.paginate(visible, capacity: gridCapacity)
      + LaunchpadLayout.paginate(unavailable, capacity: gridCapacity)
    guard pages != layout.pages else { return }
    layout.pages = pages
    refreshResults(preservingSelection: true)
  }

  private func saveLayout() {
    layoutStore?.save(layout)
    refreshResults(preservingSelection: true)
  }

  @objc private func toggleEditing() { setEditing(!isEditing) }

  func setEditing(_ value: Bool) {
    guard browsingMode == .grid else { return }
    guard isEditing != value else { return }
    isEditing = value
    renderPage()
  }

  @objc private func closeFolder() {
    panel?.makeFirstResponder(field)
    animateFolderExit()
    let previousFolder = parentFolderID ?? folderID
    folderID = nil
    field?.stringValue = ""
    refreshResults()
    if let index = results.firstIndex(where: { $0.id == previousFolder }) {
      selectedIndex = index
      renderPage()
    }
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

  @objc private func confirmRemoval(_ sender: NSButton) {
    guard browsingMode == .grid, results.indices.contains(sender.tag), let panel,
      removalTask == nil
    else { return }
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
      guard response == .alertSecondButtonReturn, self.browsingMode == .grid else { return }
      guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL == url }) else {
        self.showRemovalError()
        return
      }
      self.removeApplication(command)
    }
  }

  func removeApplication(_ command: AppCommand) {
    guard browsingMode == .grid, removalTask == nil, let session = sessionID,
      case .openApplication(let url) = command.action
    else { return }
    _ = LauncherApplicationCatalog.shared
    let applicationRemover = applicationRemover
    removalTask = Task { [weak self] in
      let worker = Task.detached(priority: .userInitiated) {
        try applicationRemover(url)
      }
      do {
        try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: {
          worker.cancel()
        }
        if !Task.isCancelled, let self, self.sessionID == session {
          self.removalTask = nil
          self.catalogTask?.cancel()
          self.catalogTask = nil
          self.catalogRequestID = nil
          self.layout.remove(command.id)
          self.applicationMap.removeValue(forKey: command.id)
          self.search = self.search?.removing(command.id)
          self.saveLayout()
        }
        // 实际删除成功即通知所有入口；窗口关闭或换会话不应吞掉这个结果。
        // 当前会话先更新布局并取消旧扫描，再通知触发重载，避免旧清单重新加入被删项。
        NotificationCenter.default.post(name: .launcherApplicationsChanged, object: nil)
        Logger(subsystem: Log.subsystem, category: "Launchpad").info("Application moved to Trash")
      } catch {
        guard !Task.isCancelled, let self, self.sessionID == session else { return }
        self.removalTask = nil
        self.showRemovalError()
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
  var onSwipe: (NSEvent) -> Void = { _ in }
  var onDismiss: () -> Void = {}
  private var scrollAmount: CGFloat = 0
  private var lastScrollTime: TimeInterval = 0
  private var lastPageTime: TimeInterval = 0
  private var horizontalSwipe: Bool?

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
    if event.hasPreciseScrollingDeltas && !event.phase.isEmpty {
      if event.phase.contains(.began) {
        horizontalSwipe = nil
        scrollAmount = 0
      }
      if horizontalSwipe == nil,
        max(abs(event.scrollingDeltaX), abs(event.scrollingDeltaY)) > 2
      {
        horizontalSwipe = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
      }
      if horizontalSwipe == true {
        onSwipe(event)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
          horizontalSwipe = nil
        }
        return
      }
    }
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
