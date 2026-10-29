import AppKit
import Localization
import SwiftUI

/// 菜单栏图标：每项独立时一个指标一个图标，点击弹出该项详情；合并时只有一个图标，点击弹出状态总览，
/// 总览中的指标行可以原地展开各项详情；聚合模式也可选择直接点击指标打开独立详情。
@MainActor
final class MenuBarController: NSObject {
  private let model: AppModel
  private let makeDockImage: @MainActor (TrioReading, TrioConfiguration) -> NSImage
  private var items: [(key: MenuBarItem?, statusItem: NSStatusItem)] = []
  private var panels: [MenuBarItem: StatusPanel] = [:]
  /// 合并模式的面板：状态总览与各项详情
  private var combinedPanel: StatusPanel?
  private var combinedRendering: MenuBarRenderer.Rendering?
  private var opensCombinedDetails = false
  private var layoutSignature: [MenuBarItem?] = []
  // 每个实际状态项只保留上一轮读数；布局、设置或外观变化时失效。
  private var renderedReadings:
    [MenuBarItem?: (reading: MenuBarReading, appearance: NSAppearance.Name)] = [:]

  private var renderedTrio:
    (reading: TrioReading, configuration: TrioConfiguration, appearance: NSAppearance.Name)?
  private var renderedDockTrio:
    (reading: TrioReading, configuration: TrioConfiguration, language: AppLanguage)?
  private var renderedItemSpacing: Int?

  /// 开发调试：启动后展开并固定某个弹窗
  var pinsNextPopover = false

  var combinedButton: NSStatusBarButton? {
    items.first { $0.key == nil }?.statusItem.button
  }

  init(
    model: AppModel,
    makeDockImage: @escaping @MainActor (TrioReading, TrioConfiguration) -> NSImage =
      TrioIconRenderer
      .dockImage
  ) {
    self.model = model
    self.makeDockImage = makeDockImage
    super.init()
  }

  // MARK: 图标

  /// 布局或显示项目变化时重建；否则只重绘图片
  func update() {
    let settings = model.settings
    let enabled = model.visibleMenuBarItems
    let opensDetails = settings.menuBarLayout == .combined && settings.combinedItemDetailsEnabled
    if opensDetails != opensCombinedDetails {
      dismissPopovers()
      opensCombinedDetails = opensDetails
    }
    if opensDetails, let item = model.openPopover,
      combinedRendering?.itemFrames[item] != nil, !enabled.contains(item)
    {
      panels[item]?.dismiss()
    }
    if let tab = model.combinedPopoverTab, !model.visibleOverviewItems.contains(tab) {
      model.combinedPopoverTab = nil
    }
    // 没有任何项目时保留一个图标，确保仍能打开面板与主窗口
    let signature: [MenuBarItem?] =
      settings.menuBarLayout == .separate && !enabled.isEmpty ? enabled : [nil]
    if signature != layoutSignature {
      rebuild(signature)
    }
    refreshImages(force: true)
  }

  private func rebuild(_ signature: [MenuBarItem?]) {
    dismissPopovers()
    // 移除图标时系统会清掉它记住的位置；先记下用户 ⌘ 拖动后的位置，重建后放回
    let defaults = UserDefaults.standard
    let positions = items.compactMap { entry -> (String, Any)? in
      let key = Self.positionKey(entry.key)
      return defaults.object(forKey: key).map { (key, $0) }
    }
    for entry in items { NSStatusBar.system.removeStatusItem(entry.statusItem) }
    for (key, value) in positions { defaults.set(value, forKey: key) }
    items = []
    renderedReadings.removeAll()
    combinedRendering = nil
    panels = panels.filter { key, _ in signature.contains(key) }
    layoutSignature = signature

    // 新建的状态栏图标出现在已有图标左侧，倒序创建才能保持从左到右的顺序
    for key in signature.reversed() {
      let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      // 按项目命名后，系统会记住每个图标被 ⌘ 拖动后的位置，下次启动保持原顺序
      statusItem.autosaveName = Self.autosaveName(key)
      if let button = statusItem.button {
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
      }
      items.insert((key, statusItem), at: 0)
    }
  }

  private static func autosaveName(_ key: MenuBarItem?) -> String {
    "XStats.\(key?.rawValue ?? "combined")"
  }

  private static func positionKey(_ key: MenuBarItem?) -> String {
    "NSStatusItem Preferred Position \(autosaveName(key))"
  }

  func refreshImages(force: Bool = false) {
    let settings = model.settings
    if settings.menuBarLayout == .iconOnly {
      let reading = TrioReading(model: model)
      refreshDockIcon(reading: reading)
      guard let button = items.first?.statusItem.button else { return }
      combinedRendering = nil
      if force { button.setAccessibilityCustomActions(nil) }
      let appearance = button.effectiveAppearance
      let sameImage =
        renderedTrio.map {
          reading.hasSameImage(as: $0.reading, configuration: settings.trio)
        } ?? false
      if force || !sameImage || renderedTrio?.configuration != settings.trio
        || renderedTrio?.appearance != appearance.name
      {
        button.image = TrioIconRenderer.image(
          reading: reading, configuration: settings.trio,
          dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        renderedTrio = (reading, settings.trio, appearance.name)
      }
      let tooltip = reading.tooltip(settings.trio)
      if button.toolTip != tooltip {
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.image?.accessibilityDescription = tooltip
      }
      return
    }
    refreshDockIcon()
    renderedTrio = nil
    if renderedItemSpacing != settings.menuBarItemSpacing {
      renderedReadings.removeAll()
      renderedItemSpacing = settings.menuBarItemSpacing
    }
    let reading = MenuBarReading(model: model, items: model.drawnMenuBarItems)
    for (index, entry) in items.enumerated() {
      let itemsToDraw = entry.key.map { [$0] } ?? model.drawnMenuBarItems
      var entryReading = reading
      // 防休眠标记只画在最左侧的图标里
      entryReading.keepAwake = reading.keepAwake && index == 0
      guard let button = entry.statusItem.button else { continue }
      let appearance = button.effectiveAppearance.name
      let previous = renderedReadings[entry.key]
      let unchanged =
        previous.map { previous in
          previous.appearance == appearance && entryReading.keepAwake == previous.reading.keepAwake
            && itemsToDraw.allSatisfy {
              entryReading.hasSameImage(
                as: previous.reading, item: $0, style: settings.style(for: $0))
            }
        } ?? false
      if force || !unchanged {
        let rendering = MenuBarRenderer.render(
          reading: entryReading, items: itemsToDraw,
          style: { settings.style(for: $0) },
          networkStyle: settings.networkStyle,
          colorizeHighLoad: settings.colorizeHighLoad,
          fahrenheit: settings.useFahrenheit,
          itemGap: CGFloat(settings.menuBarItemSpacing),
          valueOnTop: settings.menuBarValueOnTop,
          loadSensitivity: settings.loadSensitivity)
        button.image = rendering.image
        if entry.key == nil { combinedRendering = rendering }
        renderedReadings[entry.key] = (entryReading, appearance)
      }
      // 操作列表只随设置和布局更新，不随每次读数重建。
      if force {
        // 单个系统按钮仍可通过 VoiceOver 的操作菜单访问各指标。
        if entry.key == nil, opensCombinedDetails {
          button.setAccessibilityCustomActions(
            itemsToDraw.map { item in
              NSAccessibilityCustomAction(name: item.title) { [weak self] in
                self?.showPopover(item) ?? false
              }
            } + [
              NSAccessibilityCustomAction(name: tr("状态总览")) { [weak self] in
                self?.showOverview() ?? false
              }
            ])
        } else {
          button.setAccessibilityCustomActions(nil)
        }
      }
      // 额度的重置时间、过期状态等只影响提示，不必重画相同图像。
      let tooltip =
        itemsToDraw.isEmpty
        ? "XStats" : reading.tooltip(items: itemsToDraw, fahrenheit: settings.useFahrenheit)
      if button.toolTip != tooltip { button.toolTip = tooltip }
      button.setAccessibilityLabel(tooltip)
    }
  }

  /// 共用现有采样刷新；隐藏程序坞时释放动态图标，重新显示时立即补上当前状态。
  func refreshDockIcon(reading: TrioReading? = nil) {
    guard model.settings.menuBarLayout == .iconOnly, NSApp.activationPolicy() == .regular else {
      if renderedDockTrio != nil {
        NSApp.applicationIconImage = nil
        renderedDockTrio = nil
      }
      return
    }
    let reading = reading ?? TrioReading(model: model)
    let configuration = model.settings.trio
    let language = model.settings.language
    let sameImage =
      renderedDockTrio.map {
        reading.hasSameImage(as: $0.reading, configuration: configuration)
      } ?? false
    let tooltip = reading.tooltip(configuration)
    if NSApp.applicationIconImage?.accessibilityDescription != tooltip {
      NSApp.applicationIconImage?.accessibilityDescription = tooltip
    }
    guard
      !sameImage || renderedDockTrio?.configuration != configuration
        || renderedDockTrio?.language != language
    else { return }
    NSApp.applicationIconImage = makeDockImage(reading, configuration)
    renderedDockTrio = (reading, configuration, language)
  }

  // MARK: 点击

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    handleClick(sender, event: NSApp.currentEvent)
  }

  func handleClick(_ sender: NSStatusBarButton, event: NSEvent?) {
    guard let entry = items.first(where: { $0.statusItem.button === sender }) else { return }
    if event?.type == .rightMouseUp {
      showContextMenu(for: entry.statusItem)
    } else if let key = entry.key {
      togglePopover(key, button: sender)
    } else if opensCombinedDetails, let event, event.type == .leftMouseUp,
      event.window === sender.window,
      let imageFrame = sender.cell?.imageRect(forBounds: sender.bounds),
      let item = combinedRendering?.item(
        at: sender.convert(event.locationInWindow, from: nil), in: imageFrame)
    {
      togglePopover(item, button: sender)
    } else {
      toggleCombinedPanel(tab: nil, button: sender)
    }
  }

  func togglePopover(_ item: MenuBarItem, button: NSStatusBarButton? = nil) {
    let individualButton = button ?? items.first(where: { $0.key == item })?.statusItem.button
    let combinedButton = opensCombinedDetails ? self.combinedButton : nil
    // 未开启逐项点击时，快捷入口继续在总览中展开详情。
    guard let button = individualButton ?? combinedButton else {
      toggleCombinedPanel(tab: item, button: nil)
      return
    }
    guard let window = button.window else { return }
    combinedPanel?.dismiss()
    for (key, panel) in panels where key != item { panel.dismiss() }
    let localFrame =
      (button === self.combinedButton
        ? button.cell.flatMap {
          combinedRendering?.frame(for: item, in: $0.imageRect(forBounds: button.bounds))
        } : nil) ?? button.bounds
    let frame = window.convertToScreen(button.convert(localFrame, to: nil))
    let panel = self.panel(for: item)
    panel.toggle(below: frame, on: window.screen)
    if pinsNextPopover, panel.isVisible {
      panel.isPinned = true
      pinsNextPopover = false
    }
  }

  /// 外部打开请求保持幂等；合并面板已打开时只切换展开项，不把再次打开解释为关闭。
  @discardableResult func showPopover(_ item: MenuBarItem) -> Bool {
    if model.isCombinedPopoverOpen, !opensCombinedDetails {
      model.combinedPopoverTab = item
      combinedPanel?.refreshHeight()
      return true
    }
    if model.openPopover == item { return true }
    togglePopover(item)
    return panels[item]?.isVisible == true || combinedPanel?.isVisible == true
  }

  /// 合并模式的状态总览
  func toggleOverview() {
    toggleCombinedPanel(tab: nil, button: nil)
  }

  @discardableResult func showOverview() -> Bool {
    if model.isCombinedPopoverOpen {
      model.combinedPopoverTab = nil
      combinedPanel?.refreshHeight()
      return true
    }
    toggleOverview()
    return combinedPanel?.isVisible == true
  }

  /// 合并模式：点图标打开时总是先看收起的总览；从快捷入口打开某一项时直接展开该行
  private func toggleCombinedPanel(tab: MenuBarItem?, button: NSStatusBarButton?) {
    guard let button = button ?? items.first(where: { $0.key == nil })?.statusItem.button,
      let window = button.window
    else { return }
    for panel in panels.values { panel.dismiss() }
    let panel = combinedPanel ?? makeCombinedPanel()
    if !panel.isVisible { model.combinedPopoverTab = tab }
    let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
    panel.toggle(below: frame, on: window.screen)
    if pinsNextPopover, panel.isVisible {
      panel.isPinned = true
      pinsNextPopover = false
    }
  }

  private func makeCombinedPanel() -> StatusPanel {
    let model = self.model
    let panel = StatusPanel(
      width: DS.Size.combinedPopoverWidth, minHeight: DS.Size.panelMinHeight / 2,
      content: { CombinedPopoverView().environment(model) },
      measuring: { CombinedPopoverView().environment(model).environment(\.isSnapshot, true) })
    panel.onVisibilityChange = { [weak self] visible in
      guard let self else { return }
      self.model.isCombinedPopoverOpen = visible
      if visible { self.model.helper.refreshStatus() }
      self.combinedButton?.highlight(visible || self.model.openPopover != nil)
    }
    combinedPanel = panel
    return panel
  }

  func dismissPopovers() {
    for panel in panels.values { panel.dismiss() }
    combinedPanel?.dismiss()
  }

  func refreshPopoverHeight() {
    for panel in panels.values { panel.refreshHeight() }
    combinedPanel?.refreshHeight()
  }

  private func panel(for item: MenuBarItem) -> StatusPanel {
    if let panel = panels[item] { return panel }
    let model = self.model
    let panel = StatusPanel(
      width: DS.Size.popoverWidth,
      content: { PopoverRootView(item: item).environment(model) },
      measuring: { PopoverRootView(item: item).environment(model).environment(\.isSnapshot, true) })
    panel.onVisibilityChange = { [weak self] visible in
      guard let self else { return }
      if visible {
        self.model.openPopover = item
        self.model.helper.refreshStatus()
      } else if self.model.openPopover == item {
        self.model.openPopover = nil
      }
      self.items.first { $0.key == item }?.statusItem.button?.highlight(visible)
      if self.opensCombinedDetails {
        self.combinedButton?.highlight(
          self.model.openPopover != nil || self.model.isCombinedPopoverOpen)
      }
    }
    panels[item] = panel
    return panel
  }

  private func showContextMenu(for statusItem: NSStatusItem) {
    dismissPopovers()
    let menu = contextMenu()
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  func contextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: tr("打开 XStats"), action: #selector(openMainWindow), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: tr("设置…"), action: #selector(openSettings), keyEquivalent: ",").target =
      self
    if model.settings.menuBarLayout == .combined {
      menu.addItem(withTitle: tr("状态总览"), action: #selector(openOverview), keyEquivalent: "")
        .target = self
    }
    menu.addItem(.separator())
    let awake = menu.addItem(
      withTitle: tr("防休眠"), action: #selector(toggleKeepAwake), keyEquivalent: "")
    awake.target = self
    awake.state = model.keepAwake.isActive ? .on : .off
    let durations = NSMenu()
    for duration in KeepAwakeController.Duration.allCases {
      let item = durations.addItem(
        withTitle: duration.title, action: #selector(selectKeepAwakeDuration(_:)), keyEquivalent: ""
      )
      item.target = self
      item.representedObject = duration.rawValue
      item.state = model.keepAwake.duration == duration ? .on : .off
    }
    menu.addItem(withTitle: tr("持续时间"), action: nil, keyEquivalent: "").submenu = durations
    if model.settings.isModuleEnabled(.thermal), model.store.supportsFans {
      let modes = NSMenu()
      for mode in FanController.Mode.allCases where mode != .custom {
        let item = modes.addItem(
          withTitle: mode.title, action: #selector(selectFanMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode.rawValue
        item.state = model.fans.mode == mode ? .on : .off
        item.isEnabled = !model.fans.isApplying
      }
      modes.autoenablesItems = false
      menu.addItem(withTitle: tr("散热模式"), action: nil, keyEquivalent: "").submenu = modes
    }
    menu.addItem(.separator())
    menu.addItem(
      withTitle: tr("退出 XStats"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    return menu
  }

  @objc private func toggleKeepAwake() { model.requestKeepAwake(!model.keepAwake.isActive) }

  @objc private func selectKeepAwakeDuration(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? Int,
      let duration = KeepAwakeController.Duration(rawValue: value)
    else { return }
    model.requestKeepAwake(true, duration: duration)
  }

  @objc private func selectFanMode(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? String,
      let mode = FanController.Mode(rawValue: value)
    else { return }
    model.requestFanMode(mode)
  }

  @objc private func openMainWindow() { model.openMainWindow(nil) }
  @objc private func openOverview() { showOverview() }
  @objc private func openSettings() { model.openSettings() }
}
