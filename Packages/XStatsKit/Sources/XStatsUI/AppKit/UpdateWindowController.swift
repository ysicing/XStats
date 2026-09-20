// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import Localization
import SwiftUI

/// 升级提示窗口：显示新版本摘要与“一键安装”
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    func refreshLanguage() { window?.title = tr("软件更新") }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = tr("软件更新")
        WindowChrome.apply(to: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: UpdatePromptView { [weak window] in window?.performClose(nil) }.environment(model))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 正在替换应用时不允许关闭，避免用户以为已取消
        ![.verifying, .installing].contains(model.updates.phase)
    }
}
