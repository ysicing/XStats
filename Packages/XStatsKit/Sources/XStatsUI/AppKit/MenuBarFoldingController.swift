// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Observation

/// macOS 27 按应用切换系统显示开关；较早系统沿用状态项占位。
@MainActor
final class MenuBarFoldingController: NSObject {
  private let settings: AppSettings
  private let applicationFolding: MenuBarApplicationFolding?
  private var arrow: NSStatusItem?
  private var divider: NSStatusItem?
  private var started = false
  private var awaitingLayout = false
  private(set) var isCollapsed = false

  init(
    settings: AppSettings, applicationFolding: MenuBarApplicationFolding? = nil,
    usesApplicationVisibility: Bool = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
      >= 27
  ) {
    self.settings = settings
    self.applicationFolding =
      usesApplicationVisibility
      ? (applicationFolding ?? MenuBarApplicationFolding(settings: settings)) : nil
    super.init()
  }

  func start() {
    guard !started else { return }
    started = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(expand), name: NSApplication.didChangeScreenParametersNotification,
      object: nil)
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(statusItemLayoutChanged), name: name, object: nil)
    }
    observeSettings()
  }

  func stop() {
    started = false
    NotificationCenter.default.removeObserver(self)
    removeItems()
  }

  private func observeSettings() {
    guard started else { return }
    withObservationTracking {
      _ = settings.menuBarFoldingEnabled
      _ = settings.language
      _ = applicationFolding?.isCollapsed
      _ = applicationFolding?.isBusy
      _ = applicationFolding?.recoveryNeeded
      _ = applicationFolding?.issue
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeSettings() }
    }
    if let applicationFolding {
      applicationFolding.setEnabled(settings.menuBarFoldingEnabled)
      isCollapsed = applicationFolding.isCollapsed
      // 恢复失败时保留恢复入口，即使用户已关闭开关。
      if settings.menuBarFoldingEnabled || applicationFolding.recoveryNeeded {
        if arrow == nil {
          arrow = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
          arrow?.autosaveName = "XStats.Folding.Arrow"
        }
        updateButtons()
      } else {
        removeItems()
      }
    } else if settings.menuBarFoldingEnabled {
      if arrow == nil {
        isCollapsed = settings.menuBarFoldingCollapsed
        // 新状态项通常插在左侧；恢复的系统排列仍可能改变这两个项目的相对位置。
        let arrow = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        arrow.autosaveName = "XStats.Folding.Arrow"
        self.arrow = arrow
        let divider = NSStatusBar.system.statusItem(withLength: 12)
        divider.autosaveName = "XStats.Folding.Divider"
        self.divider = divider
        Log.app.info("Menu bar folding enabled, collapsed: \(self.isCollapsed)")
      }
      updateButtons()
    } else {
      removeItems()
    }
  }

  @objc func toggle() {
    if let applicationFolding {
      if settings.menuBarFoldingEnabled || applicationFolding.recoveryNeeded {
        applicationFolding.toggle()
      }
      return
    }
    guard divider != nil else { return }
    isCollapsed.toggle()
    settings.menuBarFoldingCollapsed = isCollapsed
    updateButtons()
  }

  @objc func expand() {
    if let applicationFolding {
      applicationFolding.expand()
      return
    }
    isCollapsed = false
    updateButtons()
  }

  @objc private func statusItemLayoutChanged(_ notification: Notification) {
    guard awaitingLayout, let window = notification.object as? NSWindow,
      window === arrow?.button?.window || window === divider?.button?.window
    else { return }
    updateButtons()
  }

  private func ensureArrowOnRight() -> Bool {
    guard let arrow, let divider,
      let arrowWindow = arrow.button?.window, let dividerWindow = divider.button?.window,
      let screen = arrowWindow.screen, screen == dividerWindow.screen,
      arrowWindow.frame.height > 0, dividerWindow.frame.height > 0,
      screen.frame.intersects(arrowWindow.frame), screen.frame.intersects(dividerWindow.frame),
      arrowWindow.frame.midX != dividerWindow.frame.midX
    else { return false }
    if arrowWindow.frame.midX < dividerWindow.frame.midX {
      // 交换职责而非移动系统图标，确保恢复入口在占位右侧；保留各状态项的位置标识。
      self.arrow = divider
      self.divider = arrow
    }
    return true
  }

  private func updateButtons() {
    if let applicationFolding {
      let title =
        applicationFolding.recoveryNeeded || isCollapsed
        ? tr("展开菜单栏图标") : tr("收起菜单栏图标")
      arrow?.button?.title = ""
      arrow?.button?.target = self
      arrow?.button?.action = #selector(toggle)
      arrow?.button?.isEnabled = !applicationFolding.isBusy
      arrow?.button?.image = NSImage(
        systemSymbolName: isCollapsed ? "chevron.left" : "chevron.right",
        accessibilityDescription: title)
      arrow?.button?.toolTip = applicationFolding.issue ?? title
      arrow?.button?.setAccessibilityLabel(title)
      return
    }
    // 初始窗口坐标尚未就绪时先保留展开布局，等待原生布局通知后再恢复折叠。
    let canCollapse = !isCollapsed || (divider?.length ?? 0) > 12 || ensureArrowOnRight()
    awaitingLayout = !canCollapse
    // 较早系统保留原有占位尺寸；macOS 27 已在上方使用应用显示开关。
    let screenWidth = NSScreen.screens.map(\.frame.width).min() ?? 1512
    divider?.button?.image = nil
    // 不使用 isTransparent 隐藏标题：macOS 27 的菜单栏宿主仍可能绘制标题内容。
    divider?.button?.title = ""
    divider?.button?.target = nil
    divider?.button?.action = nil
    divider?.length = isCollapsed && canCollapse ? screenWidth / 2 - 20 : 12
    let title = isCollapsed ? tr("展开菜单栏图标") : tr("收起菜单栏图标")
    arrow?.length = NSStatusItem.variableLength
    arrow?.button?.title = ""
    arrow?.button?.target = self
    arrow?.button?.action = #selector(toggle)
    arrow?.button?.image = NSImage(
      // 箭头指向操作后的移动方向：向左展开隐藏区，向右收起。
      systemSymbolName: isCollapsed ? "chevron.left" : "chevron.right",
      accessibilityDescription: title)
    arrow?.button?.toolTip = title
    arrow?.button?.setAccessibilityLabel(title)
    divider?.button?.toolTip = tr("按住 ⌘ 将不常用图标拖到透明分隔区左侧，保留箭头在右侧。点击箭头收起或展开；效果取决于屏幕空间。")
    divider?.button?.setAccessibilityLabel(divider?.button?.toolTip)
  }

  private func removeItems() {
    if applicationFolding == nil { expand() }
    // 旧版 AppKit 移除状态项会清除位置；保存其偏好。macOS 27 由系统自行管理排列。
    let defaults = UserDefaults.standard
    let positions = [divider, arrow].compactMap { item -> (String, Any)? in
      guard let name = item?.autosaveName else { return nil }
      let key = "NSStatusItem Preferred Position \(name)"
      return defaults.object(forKey: key).map { (key, $0) }
    }
    if let divider { NSStatusBar.system.removeStatusItem(divider) }
    if let arrow { NSStatusBar.system.removeStatusItem(arrow) }
    for (key, value) in positions { defaults.set(value, forKey: key) }
    if divider != nil { Log.app.info("Menu bar folding disabled, items restored") }
    divider = nil
    arrow = nil
  }
}
