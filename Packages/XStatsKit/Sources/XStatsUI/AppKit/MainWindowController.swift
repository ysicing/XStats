import AppKit
import SwiftUI

/// 主窗口。应用默认只在菜单栏运行，窗口开着也不占程序坞；设置里打开“在程序坞显示图标”后才出现在程序坞与 ⌘Tab 中
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }
    /// 登录窗口等系统面板挂靠用
    var nsWindow: NSWindow? { window }

    func close() {
        window?.performClose(nil)
    }

    func show(tab: PanelTab?) {
        if let tab { model.settings.panelTab = tab }
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            window.setFrame(initialFrame(for: window), display: false)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        model.isMainWindowVisible = true
        onVisibilityChange?(true)
    }

    private func makeWindow() -> NSWindow {
        let width = DS.Size.sidebarWidth + DS.Size.panelWidth
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DS.Size.sidebarWidth + DS.Size.windowDefaultContentWidth,
                                                  height: DS.Size.panelMinHeight * 2),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "XStats"
        WindowChrome.apply(to: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: width, height: DS.Size.panelMinHeight * 1.5)
        // 默认尺寸调大后换一个保存名，旧的小窗口尺寸不再沿用
        window.setFrameAutosaveName("XStatsMainWindow.v2")
        window.contentView = NSHostingView(rootView: MainWindowView().environment(model))
        return window
    }

    /// 首次打开时按仪表盘内容高度确定窗口大小，之后沿用用户调整过的尺寸
    private func initialFrame(for window: NSWindow) -> NSRect {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        if window.frame.height > DS.Size.panelMinHeight * 2, visible.intersects(window.frame) {
            return window.frame
        }
        let measuring = NSHostingView(rootView: MainWindowView().environment(model).environment(\.isSnapshot, true))
        let height = min(measuring.fittingSize.height, visible.height - DS.Space.s12)
        // 至少 720pt 高（屏幕放得下时），页面较短也不会开成一个小窗口
        let size = NSSize(width: min(window.frame.width, visible.width - DS.Space.s12),
                          height: min(max(height, DS.Size.windowDefaultHeight), visible.height - DS.Space.s12))
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func windowWillClose(_ notification: Notification) {
        model.isMainWindowVisible = false
        onVisibilityChange?(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model.isMainWindowVisible = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model.isMainWindowVisible = true
    }
}

/// XStats 窗口的统一外观：透明标题栏，内容铺满整个窗口，底色与页面一致
@MainActor
enum WindowChrome {
    static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .dsBackground
        // 空的标准工具栏让标题栏与顶栏同高（52pt），红绿灯按钮与页面标题、右上角按钮对齐
        let toolbar = NSToolbar(identifier: "XStats.\(window.title)")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

}
