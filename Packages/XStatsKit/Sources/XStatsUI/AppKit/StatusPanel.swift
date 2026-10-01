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
    private var dismissedByAnchorMouseDown = false
    /// 失焦回调可能晚于下一次打开；旧轮次不能关闭重新打开的窗口。
    private var presentationGeneration: UInt = 0
    private var heightRefreshPending = false
    private var liveContentHeight: CGFloat?

    /// 面板隐藏时不保留 SwiftUI 视图，避免后台随数据刷新重绘
    private var makeContent: (() -> NSView)?
    /// 平铺布局（不含滚动容器）的视图，只用来测量内容的自然高度
    private let makeMeasuringContent: () -> NSView
    private let width: CGFloat
    /// 内容再少也不低于这个高度；合并模式的状态总览项目少时很矮，用更小的下限
    private let minHeight: CGFloat
    private let maxHeight: CGFloat?

    init<Content: View, Measuring: View>(width: CGFloat, minHeight: CGFloat = DS.Size.panelMinHeight,
                                         maxHeight: CGFloat? = nil,
                                         content: @escaping () -> Content, measuring: @escaping () -> Measuring) {
        self.width = width
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        makeMeasuringContent = { NSHostingView(rootView: measuring()) }
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: minHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)
        // 保留正在显示的视图状态；几何回调报告绝对高度，下一轮合并更新窗口。
        makeContent = { [weak self] in
            NSHostingView(rootView: content().environment(\.reportPopoverHeight, PopoverHeightReporter { height in
                self?.updateContentHeight(height)
            }))
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
        } else if !dismissedByAnchorMouseDown || Date().timeIntervalSince(lastDismissal) > 0.3 {
            // 面板打开时点击菜单栏图标：按下时面板已因失焦关闭，松开时不应再次打开
            present(below: anchor, on: screen)
        } else {
            // 只消费这一次 mouse-up；下一次独立点击不必等满冷却时间。
            dismissedByAnchorMouseDown = false
        }
    }

    func present(below anchor: NSRect, on screen: NSScreen?) {
        self.anchor = anchor
        anchorScreen = screen
        liveContentHeight = nil

        guard let content = makeContent?() else { return }
        presentationGeneration &+= 1
        dismissedByAnchorMouseDown = false
        setFrame(targetFrame(), display: false)
        content.frame = NSRect(origin: .zero, size: frame.size)
        contentView = PanelContainer.make(containing: content, cornerRadius: DS.Radius.xl)

        // 可见性不能依赖透明度动画是否被调度；非激活面板始终以完整透明度显示。
        // 窗口过渡沿用 animationBehavior，避免快速切换或繁忙布局留下透明窗口。
        alphaValue = 1
        makeKeyAndOrderFront(nil)
        installMonitors()
        onVisibilityChange?(true)
    }

    /// 内容区块变化后重新计算高度，保持顶部对齐。
    /// 直接设置而不做窗口动画：动画期间 SwiftUI 会逐帧重排，看起来像抖动
    func refreshHeight() {
        guard isVisible else { return }
        let frame = targetFrame()
        guard frame != self.frame else { return }
        setFrame(frame, display: true)
        invalidateShadow()
    }

    /// 保留最后一条绝对高度，不在 SwiftUI 布局回调内同步 setFrame。
    /// 高度来自当前视图，不能用新建视图的默认 @State 覆盖用户正在编辑或筛选的内容。
    func updateContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        guard liveContentHeight != height else { return }
        liveContentHeight = height
        guard !heightRefreshPending else { return }
        heightRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightRefreshPending = false
            self.refreshHeight()
        }
    }

    func dismiss(triggeredBy event: NSEvent? = nil) {
        guard isVisible, !isPinned else { return }
        presentationGeneration &+= 1
        lastDismissal = Date()
        // 图标 mouse-down 引起的关闭才短暂拦截 mouse-up，避免同一次点击立刻重开。
        // 点击外部、Esc 和程序化关闭不阻挡下一次打开。
        let point = event.map { $0.window?.convertPoint(toScreen: $0.locationInWindow) ?? $0.locationInWindow }
        dismissedByAnchorMouseDown = event?.type == .leftMouseDown && point.map(anchor.contains) == true
        removeMonitors()
        // 关闭立即生效；异步淡出不仅会晚到清理内容，还可能把新窗口的透明度改回 0。
        // 沿用窗口原生动画，不为短暂的关闭过渡维护额外状态与取消机制。
        orderOut(nil)
        contentView = nil
        alphaValue = 1
        onVisibilityChange?(false)
    }

    override func resignKey() {
        let generation = presentationGeneration
        let event = NSApp.currentEvent
        super.resignKey()
        // 弹出菜单时面板也会失去 key，稍后确认没有其他 key 窗口再关闭
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentationGeneration == generation,
                      self.isVisible, !self.isKeyWindow, self.attachedSheet == nil else { return }
                if NSApp.keyWindow?.level == .popUpMenu { return }
                self.dismiss(triggeredBy: event)
            }
        }
    }

    // MARK: 尺寸

    private func targetFrame() -> NSRect {
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        let natural = liveContentHeight ?? makeMeasuringContent().fittingSize.height
        let preferredHeight = min(max(natural, minHeight), maxHeight ?? .greatestFiniteMagnitude)
        return Self.constrainedFrame(anchor: anchor, visible: visible,
                                     preferredSize: NSSize(width: width, height: preferredHeight))
    }

    /// 显示器可用区始终优先于首选尺寸，窄屏和低分辨率下不能让最小高度把面板挤出屏幕。
    static func constrainedFrame(anchor: NSRect, visible: NSRect, preferredSize: NSSize) -> NSRect {
        let margin = DS.Space.s2
        let top = min(anchor.minY - DS.Size.panelGap, visible.maxY)
        let height = min(preferredSize.height, max(1, top - visible.minY - margin))
        let fittedWidth = min(preferredSize.width, max(1, visible.width - 2 * margin))
        var x = anchor.midX - fittedWidth / 2
        x = min(max(x, visible.minX + margin), visible.maxX - fittedWidth - margin)
        return NSRect(x: x, y: top - height, width: fittedWidth, height: height)
    }

    // MARK: 事件

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.dismiss(triggeredBy: event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            // Esc
            if event.type == .keyDown, event.keyCode == 53, event.window === self {
                MainActor.assumeIsolated { self?.dismiss(triggeredBy: event) }
                return nil
            }
            // 本应用的图标点击不会进入 global monitor；在按下时记录关闭原因，
            // 不处理弹窗内的点击，避免影响下拉菜单、文本选择等原有交互。
            if event.type == .leftMouseDown, let self, event.window !== self {
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
                if self.anchor.contains(point) { self.dismiss(triggeredBy: event) }
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
