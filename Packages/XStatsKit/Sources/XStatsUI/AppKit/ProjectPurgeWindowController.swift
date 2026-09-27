// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

/// 项目产物只在独立窗口中扫描；关窗后停止尚未完成的只读扫描。
@MainActor
final class ProjectPurgeWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private(set) var isVisible = false
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func refreshLanguage() { window?.title = tr("项目产物") }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if window.isMiniaturized { window.deminiaturize(nil) }
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
        window.title = tr("项目产物")
        WindowChrome.apply(to: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: DS.Size.panelWidth - DS.Space.s16,
                                       height: DS.Size.panelMinHeight * 1.5)
        window.contentView = NSHostingView(rootView: ProjectPurgeWindowView().environment(model))
        if !window.setFrameUsingName("XStatsProjectPurgeWindow") { window.center() }
        window.setFrameAutosaveName("XStatsProjectPurgeWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
        model.projectPurge.cancelScan()
        onVisibilityChange?(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        isVisible = false
        model.projectPurge.cancelScan()
        onVisibilityChange?(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        isVisible = true
        onVisibilityChange?(true)
    }
}
