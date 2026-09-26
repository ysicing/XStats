// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization

/// 番茄钟启用时才出现的独立菜单栏入口；左键打开主页面，右键切换 Mini HUD。
@MainActor
final class RestMenuBarController: NSObject {
    private let rest: RestController
    private let open: () -> Void
    private let toggleHUD: () -> Void
    private var item: NSStatusItem?

    init(rest: RestController, open: @escaping () -> Void, toggleHUD: @escaping () -> Void) {
        self.rest = rest
        self.open = open
        self.toggleHUD = toggleHUD
        super.init()
    }

    func sync() {
        guard rest.settings.restEnabled else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            rest.setMenuBarVisible(false)
            return
        }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "XStats.rest"
            if let button = item.button {
                button.target = self
                button.action = #selector(clicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: tr("番茄钟"))
                button.image?.isTemplate = true
            }
            self.item = item
        }
        rest.setMenuBarVisible(true)
        update()
    }

    func update() {
        guard let button = item?.button else { return }
        if rest.isRunning {
            let seconds = max(0, Int(rest.secondsRemaining.rounded(.up)))
            button.title = String(format: " %02d:%02d", seconds / 60, seconds % 60)
        } else {
            button.title = ""
        }
        button.toolTip = tr("番茄钟") + " · " + tr(rest.isRunning ? "计时中" : "已暂停")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { toggleHUD() } else { open() }
    }
}
