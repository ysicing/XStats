import AppKit
import Localization
import SwiftUI

/// 出口与分流窗口。打开期间检测器盯着网络环境，关闭后停止
@MainActor
final class EgressWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
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
            model.egress.windowDidOpen()
            onVisibilityChange?(true)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DS.Size.egressWindowWidth, height: DS.Size.egressWindowHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = tr("出口与分流")
        WindowChrome.apply(to: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: DS.Size.panelWidth - DS.Space.s16, height: DS.Size.panelMinHeight * 1.5)
        window.contentView = NSHostingView(rootView: EgressWindowView().environment(model))
        // 第一次打开居中，之后沿用用户调整过的位置与大小
        if !window.setFrameUsingName("XStatsEgressWindow") { window.center() }
        window.setFrameAutosaveName("XStatsEgressWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
        model.egress.windowDidClose()
        onVisibilityChange?(false)
    }
}
