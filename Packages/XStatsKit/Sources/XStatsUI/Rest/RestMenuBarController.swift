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
                button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: tr("专注与护眼"))
                button.image?.isTemplate = true
                button.imagePosition = .imageLeading
                button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            }
            self.item = item
        }
        rest.setMenuBarVisible(true)
        update()
    }

    func update() {
        guard let button = item?.button else { return }
        if let wellness, wellness.isEyeRestActive {
            button.title = WellnessFormat.timer(wellness.eyeRestSecondsRemaining)
        } else if rest.isRunning {
            button.title = WellnessFormat.timer(rest.secondsRemaining)
        } else {
            button.title = ""
        }
        // 菜单栏入口始终用计时图标；待处理提醒不能把正在计时的入口变成隐私指示。
        // 当前阶段及护眼提醒放在悬停提示中，图标和文字均由系统适配菜单栏外观。
        let state = wellness?.isEyeRestActive == true ? tr("护眼休息")
            : rest.isRunning ? rest.phase.title
            : rest.primaryAction == .resume ? tr("已暂停") : tr("未开始专注")
        let reminder = wellness?.pending.isEmpty == false ? " · " + tr("待处理") : ""
        let description = tr("专注与护眼") + " · " + state + reminder
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { toggleHUD() } else { open() }
    }
}
