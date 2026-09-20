import AppKit
import SwiftUI

/// 弹窗窗口的底板：圆角裁切的普通容器，背景由 SwiftUI 内容绘制
@MainActor
enum PanelContainer {
    /// 容器必须从内容的尺寸开始：若从 0 开始，窗口把它撑满时自动调整会把内容再放大一倍
    static func make(containing content: NSView, cornerRadius: CGFloat) -> NSView {
        let container = NSView(frame: content.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        return container
    }
}

/// 内容铺满标题栏后，标题栏区域由 SwiftUI 接收点击；放在顶栏背后，按住空白处可以拖动窗口
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// 滚动条只在滚动时出现：把所在的 NSScrollView 固定为浮层样式。
/// 系统设置为“始终显示滚动条”或接了鼠标时，SwiftUI 默认会一直显示一条占位的滚动条
struct OverlayScrollers: NSViewRepresentable {
    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
                return
            }
            apply()
            guard observer == nil else { return }
            // 系统切换滚动条样式时会重置，收到通知后重新设置
            observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let scrollView = self?.enclosingScrollView else { return }
                    guard scrollView.scrollerStyle != .overlay || !scrollView.autohidesScrollers else { return }
                    scrollView.scrollerStyle = .overlay
                    scrollView.autohidesScrollers = true
                    // 样式改了之后重新排版，让内容占满原来留给滚动条的那一条
                    scrollView.tile()
                    scrollView.documentView?.needsLayout = true
                }
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.apply() }
}

extension View {
    /// 放在 ScrollView 的内容里：滚动条改为浮层，只在滚动时显示
    func overlayScrollers() -> some View {
        background(OverlayScrollers().frame(width: 0, height: 0))
    }
}
