// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

/// 账号配置需要在浏览器与 XStats 之间来回查找信息，因此使用可留在后台的独立窗口。
@MainActor
final class AIUsageSettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private(set) var isVisible = false
    var onVisibilityChange: ((Bool) -> Void)?
    func refreshLanguage() { window?.title = tr("AI 用量与额度") + " · " + tr("设置") }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !isVisible {
            isVisible = true
            onVisibilityChange?(true)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = tr("AI 用量与额度") + " · " + tr("设置")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 390, height: 480)
        window.contentView = NSHostingView(rootView: AIUsageSettingsPanel().environment(model))
        if !window.setFrameUsingName("XStatsAIUsageSettingsWindow") { window.center() }
        window.setFrameAutosaveName("XStatsAIUsageSettingsWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
        onVisibilityChange?(false)
    }
}
