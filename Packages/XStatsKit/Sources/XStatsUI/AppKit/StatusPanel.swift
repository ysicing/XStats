import AppKit
import SwiftUI

/// 菜单栏下方的浮动详情弹窗。点击外部、按 Esc 或切换应用时关闭。
/// 高度按内容自动计算，屏幕放得下就不出现滚动。
@MainActor
final class StatusPanel: NSPanel {
    var onVisibilityChange: ((Bool) -> Void)?
    /// 开发调试用：固定面板，不因点击外部或失去焦点而收起
    var isPinned = false

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var anchor: NSRect = .zero
    private weak var anchorScreen: NSScreen?
    private var lastDismissal = Date.distantPast

    /// 面板隐藏时不保留 SwiftUI 视图，避免后台随数据刷新重绘
    private var makeContent: (() -> NSView)?
    /// 平铺布局（不含滚动容器）的视图，只用来测量内容的自然高度
    private let makeMeasuringContent: () -> NSView
    private let width: CGFloat
    /// 内容再少也不低于这个高度；合并模式的状态总览项目少时很矮，用更小的下限
    private let minHeight: CGFloat

    init<Content: View, Measuring: View>(width: CGFloat, minHeight: CGFloat = DS.Size.panelMinHeight,
                                         content: @escaping () -> Content, measuring: @escaping () -> Measuring) {
        self.width = width
        self.minHeight = minHeight
        makeMeasuringContent = { NSHostingView(rootView: measuring()) }
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: minHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)
        // 打开时按平铺布局测出的高度只是起点：真实内容会随数据刷新变高变矮，由滚动区域上报差值再校正
        makeContent = { [weak self] in
            NSHostingView(rootView: content().environment(\.reportPopoverOverflow) { overflow in
                self?.adjustHeight(by: overflow)
            })
        }
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        isMovable = false
    }

    override var canBecomeKey: Bool { true }

    func toggle(below anchor: NSRect, on screen: NSScreen?) {
        if isVisible {
            dismiss()
        } else if Date().timeIntervalSince(lastDismissal) > 0.3 {
            // 面板打开时点击菜单栏图标：按下时面板已因失焦关闭，松开时不应再次打开
            present(below: anchor, on: screen)
        }
    }

    func present(below anchor: NSRect, on screen: NSScreen?) {
        self.anchor = anchor
        anchorScreen = screen

        guard let content = makeContent?() else { return }
        setFrame(targetFrame(), display: false)
        content.frame = NSRect(origin: .zero, size: frame.size)
        contentView = PanelContainer.make(containing: content, cornerRadius: DS.Radius.xl)

        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        installMonitors()
        onVisibilityChange?(true)
    }

    /// 内容区块变化后重新计算高度，保持顶部对齐。
    /// 直接设置而不做窗口动画：动画期间 SwiftUI 会逐帧重排，看起来像抖动
    func refreshHeight() {
        guard isVisible else { return }
        let frame = targetFrame()
        guard abs(frame.height - self.frame.height) > 1 else { return }
        setFrame(frame, display: true)
        invalidateShadow()
    }

    /// 滚动内容比可视区域高出（或矮出）一截时调整窗口高度，顶边不动；屏幕放不下时停在最高处，由滚动条兜底
    func adjustHeight(by overflow: CGFloat) {
        guard contentView != nil, abs(overflow) > 1 else { return }
        let height = min(max(frame.height + overflow, minHeight), availableHeight())
        guard abs(height - frame.height) > 1 else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height), display: true)
        invalidateShadow()
    }

    func dismiss() {
        guard isVisible, !isPinned else { return }
        lastDismissal = Date()
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.contentView = nil
                self?.alphaValue = 1
            }
        })
        onVisibilityChange?(false)
    }

    override func resignKey() {
        super.resignKey()
        // 弹出菜单时面板也会失去 key，稍后确认没有其他 key 窗口再关闭
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, !self.isKeyWindow, self.attachedSheet == nil else { return }
                if NSApp.keyWindow?.level == .popUpMenu { return }
                self.dismiss()
            }
        }
    }

    // MARK: 尺寸

    private func targetFrame() -> NSRect {
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        let margin = DS.Space.s2
        let top = min(anchor.minY - DS.Size.panelGap, visible.maxY)

        let natural = makeMeasuringContent().fittingSize.height
        let height = min(max(natural, minHeight), availableHeight())

        var x = anchor.midX - width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - width - margin)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    /// 菜单栏下方到屏幕底边（留一点边距）能放下的最大高度
    private func availableHeight() -> CGFloat {
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        let top = min(anchor.minY - DS.Size.panelGap, visible.maxY)
        return max(minHeight, top - visible.minY - DS.Space.s2)
    }

    // MARK: 事件

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Esc
            if event.keyCode == 53, event.window === self {
                MainActor.assumeIsolated { self?.dismiss() }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
