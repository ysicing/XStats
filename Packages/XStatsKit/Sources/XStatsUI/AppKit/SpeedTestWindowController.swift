// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import Localization
import SwiftUI

/// 网络测速窗口。关窗时停掉还在跑的测试，不让它继续占带宽
@MainActor
final class SpeedTestWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    func refreshLanguage() { window?.title = tr("网络测速") }
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// windowWillClose 时窗口还算可见，所以自己记开关状态
    private(set) var isVisible = false

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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DS.Size.speedTestWindowWidth,
                                                  height: DS.Size.speedTestWindowHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = tr("网络测速")
        WindowChrome.apply(to: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: DS.Size.panelWidth - DS.Space.s16, height: DS.Size.panelMinHeight * 1.5)
        window.contentView = NSHostingView(rootView: SpeedTestWindowView().environment(model))
        // 第一次打开居中，之后沿用用户调整过的位置与大小
        if !window.setFrameUsingName("XStatsSpeedTestWindow") { window.center() }
        window.setFrameAutosaveName("XStatsSpeedTestWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
        model.speedTest.windowDidClose()
        onVisibilityChange?(false)
    }
}
