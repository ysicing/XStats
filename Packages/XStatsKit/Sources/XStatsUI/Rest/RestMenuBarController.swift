// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization

/// 番茄钟启用时才出现的独立菜单栏入口；左键打开主页面，右键切换 Mini HUD。
@MainActor
final class RestMenuBarController: NSObject {
    private let rest: RestController
    private let wellness: WellnessController?
    private let open: () -> Void
    private let toggleHUD: () -> Void
    private var item: NSStatusItem?

    init(rest: RestController, wellness: WellnessController? = nil, open: @escaping () -> Void, toggleHUD: @escaping () -> Void) {
        self.rest = rest
        self.wellness = wellness
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
                button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: tr("专注与健康"))
                button.image?.isTemplate = true
            }
            self.item = item
        }
        rest.setMenuBarVisible(true)
        update()
    }

    func update() {
        guard let button = item?.button else { return }
        if let wellness, wellness.activeExercise != nil {
            button.title = " " + WellnessFormat.timer(wellness.exerciseSecondsRemaining)
        } else if rest.isRunning {
            button.title = " " + WellnessFormat.timer(rest.secondsRemaining)
        } else {
            button.title = ""
        }
        let pending = wellness?.pending ?? []
        let symbol = pending.contains(.water) ? "drop.fill" : pending.contains(.rest) ? "eye" : "timer"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tr("专注与健康"))
        button.image?.isTemplate = true
        button.toolTip = tr("专注与健康") + " · " + tr(!pending.isEmpty ? "待处理" : rest.isRunning ? "计时中" : "未开始专注")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { toggleHUD() } else { open() }
    }
}
