// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Observation

/// 仅通过原生状态项占位触发溢出，不枚举或操作其他应用的图标。
@MainActor
final class MenuBarFoldingController: NSObject {
  private let settings: AppSettings
  private var arrow: NSStatusItem?
  private var divider: NSStatusItem?
  private var started = false
  private(set) var isCollapsed = false

  init(settings: AppSettings) {
    self.settings = settings
    super.init()
  }

  func start() {
    guard !started else { return }
    started = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(expand), name: NSApplication.didChangeScreenParametersNotification,
      object: nil)
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
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeSettings() }
    }
    if settings.menuBarFoldingEnabled {
      if arrow == nil {
        // 新项目通常在左侧创建：先放箭头，再放分隔符；用户可用 ⌘ 拖动位置。
        let arrow = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        arrow.autosaveName = "XStats.Folding.Arrow"
        arrow.button?.target = self
        arrow.button?.action = #selector(toggle)
        self.arrow = arrow
        let divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        divider.autosaveName = "XStats.Folding.Divider"
        divider.button?.title = "│"
        // 只隐藏绘制，保留原有尺寸与拖动位置，避免改变折叠边界。
        divider.button?.isTransparent = true
        self.divider = divider
        Log.app.info("Menu bar folding enabled, expanded")
      }
      updateButtons()
    } else {
      removeItems()
    }
  }

  @objc func toggle() {
    guard divider != nil else { return }
    isCollapsed.toggle()
    updateButtons()
  }

  @objc func expand() {
    isCollapsed = false
    updateButtons()
  }

  private func updateButtons() {
    // 固定 500pt 在箭头靠右时仍能放下，会留下大片空白；接近半屏宽才能让占位一起溢出。
    // macOS 27 会直接丢弃达到半屏宽的状态项，因此保留 20pt 余量，不能使用超长占位。
    let screenWidth = NSScreen.screens.map(\.frame.width).min() ?? 1512
    divider?.length = isCollapsed ? screenWidth / 2 - 20 : NSStatusItem.variableLength
    let title = isCollapsed ? tr("展开菜单栏图标") : tr("收起菜单栏图标")
    arrow?.button?.image = NSImage(
      systemSymbolName: isCollapsed ? "chevron.right" : "chevron.left",
      accessibilityDescription: title)
    arrow?.button?.toolTip = title
    arrow?.button?.setAccessibilityLabel(title)
    divider?.button?.toolTip = tr("按住 ⌘ 将不常用图标拖到透明分隔区左侧，保留箭头在右侧。点击箭头收起或展开；效果取决于屏幕空间。")
  }

  private func removeItems() {
    expand()
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
