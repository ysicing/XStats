import AppKit
import Localization
import SwiftUI

/// 菜单栏图标：每项独立时一个指标一个图标，点击弹出该项详情；合并时只有一个图标，点击弹出状态总览，
/// 总览顶部的标签可以切到各项的详情
@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private var items: [(key: MenuBarItem?, statusItem: NSStatusItem)] = []
    private var panels: [MenuBarItem: StatusPanel] = [:]
    /// 合并模式的面板：状态总览与各项详情
    private var combinedPanel: StatusPanel?
    private var layoutSignature: [MenuBarItem?] = []

    /// 开发调试：启动后展开并固定某个弹窗
    var pinsNextPopover = false

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: 图标

    /// 布局或显示项目变化时重建；否则只重绘图片
    func update() {
        let settings = model.settings
        let enabled = settings.orderedMenuBarItems
        // 没有任何项目时保留一个图标，确保仍能打开面板与主窗口
        let signature: [MenuBarItem?] = settings.menuBarLayout == .separate && !enabled.isEmpty ? enabled : [nil]
        if signature != layoutSignature {
            rebuild(signature)
        }
        refreshImages()
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

    func refreshImages() {
        let settings = model.settings
        let reading = MenuBarReading(model: model)
        for (index, entry) in items.enumerated() {
            let itemsToDraw = entry.key.map { [$0] } ?? settings.orderedMenuBarItems
            var entryReading = reading
            // 防休眠标记只画在最左侧的图标里
            entryReading.keepAwake = reading.keepAwake && index == 0
            entry.statusItem.button?.image = MenuBarRenderer.image(reading: entryReading,
                                                                  items: itemsToDraw,
                                                                  style: { settings.style(for: $0) },
                                                                  networkStyle: settings.networkStyle,
                                                                  colorizeHighLoad: settings.colorizeHighLoad,
                                                                  fahrenheit: settings.useFahrenheit)
            entry.statusItem.button?.toolTip = reading.tooltip(items: itemsToDraw, fahrenheit: settings.useFahrenheit)
        }
    }

    // MARK: 点击

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let entry = items.first(where: { $0.statusItem.button === sender }) else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(for: entry.statusItem)
        } else if let key = entry.key {
            togglePopover(key, button: sender)
        } else {
            toggleCombinedPanel(tab: nil, button: sender)
        }
    }

    func togglePopover(_ item: MenuBarItem, button: NSStatusBarButton? = nil) {
        // 合并模式下没有这一项自己的图标：打开合并面板并切到这一项
        guard let button = button ?? items.first(where: { $0.key == item })?.statusItem.button else {
            toggleCombinedPanel(tab: item, button: nil)
            return
        }
        guard let window = button.window else { return }
        combinedPanel?.dismiss()
        for (key, panel) in panels where key != item { panel.dismiss() }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let panel = self.panel(for: item)
        panel.toggle(below: frame, on: window.screen)
        if pinsNextPopover, panel.isVisible {
            panel.isPinned = true
            pinsNextPopover = false
        }
    }

    /// 合并模式的状态总览
    func toggleOverview() {
        toggleCombinedPanel(tab: nil, button: nil)
    }

    /// 合并模式：点图标打开时总是先看总览；从快捷入口打开某一项时直接切到那一项
    private func toggleCombinedPanel(tab: MenuBarItem?, button: NSStatusBarButton?) {
        guard let button = button ?? items.first(where: { $0.key == nil })?.statusItem.button,
              let window = button.window else { return }
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
        let panel = StatusPanel(width: DS.Size.popoverWidth, minHeight: DS.Size.panelMinHeight / 2,
                                content: { CombinedPopoverView().environment(model) },
                                measuring: { CombinedPopoverView().environment(model).environment(\.isSnapshot, true) })
        panel.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            self.model.isCombinedPopoverOpen = visible
            if visible { self.model.helper.refreshStatus() }
            self.items.first { $0.key == nil }?.statusItem.button?.highlight(visible)
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
        let panel = StatusPanel(width: DS.Size.popoverWidth,
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
        }
        panels[item] = panel
        return panel
    }

    private func showContextMenu(for statusItem: NSStatusItem) {
        dismissPopovers()
        let menu = NSMenu()
        menu.addItem(withTitle: tr("打开 XStats"), action: #selector(openMainWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("设置…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("退出 XStats"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openMainWindow() { model.openMainWindow(nil) }
    @objc private func openSettings() { model.openSettings() }
}
