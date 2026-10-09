// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

@MainActor
final class RestPanel: NSPanel {
    var onEscape: (() -> Void)?
    var hudDragEnabled = false
    private var dragStartScreen: NSPoint?
    private var dragStartOrigin: NSPoint?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    override func sendEvent(_ event: NSEvent) {
        if hudDragEnabled {
            switch event.type {
            case .leftMouseDown where isHUDDragRegion(event.locationInWindow):
                dragStartScreen = convertPoint(toScreen: event.locationInWindow)
                dragStartOrigin = frame.origin
                return
            case .leftMouseDragged:
                if let dragStartScreen, let dragStartOrigin {
                    let current = convertPoint(toScreen: event.locationInWindow)
                    var origin = NSPoint(x: dragStartOrigin.x + current.x - dragStartScreen.x,
                                         y: dragStartOrigin.y + current.y - dragStartScreen.y)
                    if let screen = NSScreen.screens.first(where: { $0.frame.contains(current) }) ?? self.screen ?? NSScreen.main {
                        let visible = screen.visibleFrame
                        origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
                        origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
                    }
                    setFrameOrigin(origin)
                    return
                }
            case .leftMouseUp where dragStartScreen != nil:
                dragStartScreen = nil
                dragStartOrigin = nil
                return
            default: break
            }
        }
        super.sendEvent(event)
    }

    /// 下方控制按钮与顶部两个操作按钮保留正常点击，其余区域都能直接拖动。
    private func isHUDDragRegion(_ point: NSPoint) -> Bool {
        guard point.y > 52 else { return false }
        let inHeader = point.y >= frame.height - 42
        let overActionButtons = point.x < 44 || point.x > frame.width - 44
        return !inHeader || !overActionButtons
    }
}

private struct RestOverlayContent: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let rest: RestController
    let wellness: WellnessController?

    var body: some View {
        ZStack {
            if let wellness, wellness.isEyeRestActive {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) } else { Color.black.opacity(0.25) }
                WellnessEyeRestView(wellness: wellness)
            } else {
                RestOverlayView(rest: rest)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RestOverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let rest: RestController
    @State private var haloPulse = false
    @State private var holding = false

    var body: some View {
        let language = rest.settings.language.resolved
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Color.black.opacity(0.25)
            }
            VStack(spacing: 22) {
                RestCountdownRing(title: rest.phase.title, secondsRemaining: rest.secondsRemaining,
                                  duration: rest.phaseDuration,
                                  haloScale: haloPulse && !reduceMotion ? 1.12 : 0.9)
                Text(tr(rest.settings.restMode == .workday ? "起身活动一下" : "让眼睛休息一下"))
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .tracking(-1)
                Text(tr(rest.settings.restMode == .workday
                        ? "走动几步，看看远处，让身体和眼睛都休息"
                        : "看看远处，轻轻眨眼，放松肩颈"))
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Text(tr("长按跳过 · 或按 Esc 随时返回"))
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .scaleEffect(holding ? 0.96 : 1)
                        .onLongPressGesture(minimumDuration: 0.8, pressing: { holding = $0 }) { rest.skip() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { rest.skip() }
                    Button(tr("再专注 5 分钟")) { rest.postponeFiveMinutes() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .frame(maxWidth: 680)
        }
        .ignoresSafeArea()
        .environment(\.locale, L10n.locale(for: language))
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) { haloPulse = true }
        }
    }
}

/// 专注短休与护眼休息共用倒计时层级；进度沿用控制器刷新，不新增动画时钟。
struct RestCountdownRing: View {
    let title: String
    let secondsRemaining: TimeInterval
    let duration: TimeInterval
    var haloScale: CGFloat = 1

    var body: some View {
        let accent = Color(red: 0.32, green: 0.89, blue: 0.53)
        ZStack {
            Circle().fill(accent.opacity(0.20))
                .frame(width: 195, height: 195)
                .blur(radius: 28)
                .scaleEffect(haloScale)
            Circle().stroke(accent.opacity(0.22), lineWidth: 2)
            Circle()
                .trim(from: 0, to: duration > 0 ? min(1, max(0, 1 - secondsRemaining / duration)) : 0)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: DS.Space.s2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(WellnessFormat.timer(secondsRemaining))
                    .font(.system(size: 52, weight: .light, design: .rounded)).monospacedDigit()
            }
            .foregroundStyle(accent)
        }
        .frame(width: 250, height: 250)
    }
}


@MainActor
final class RestWindowController {
    private let rest: RestController
    private let wellness: WellnessController?
    private var overlays: [RestPanel] = []
    private var hud: RestPanel?
    private var screenObserver: NSObjectProtocol?

    init(rest: RestController, wellness: WellnessController? = nil) {
        self.rest = rest
        self.wellness = wellness
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreens() }
        }
    }

    func showRest() {
        hideRest()
        for screen in NSScreen.screens {
            let panel = RestPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false, screen: screen)
            panel.level = .floating
            // NSPanel 默认在应用失去前台时隐藏；幕布必须一直可见，状态才与界面一致。
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.hasShadow = false
            panel.onEscape = { [weak rest, weak wellness] in
                if wellness?.isEyeRestActive == true { wellness?.finishEyeRest(completed: false) }
                else { rest?.skip() }
            }
            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            blur.blendingMode = .behindWindow
            blur.material = .underWindowBackground
            blur.state = .active
            let hosting = NSHostingView(rootView: RestOverlayContent(rest: rest, wellness: wellness))
            hosting.frame = blur.bounds
            hosting.autoresizingMask = [.width, .height]
            blur.addSubview(hosting)
            panel.contentView = blur
            panel.orderFrontRegardless()
            overlays.append(panel)
        }
        overlays.first?.makeKey()
    }

    func ensureRestVisible() {
        if overlays.isEmpty { showRest() }
    }

    func hideRest() {
        overlays.forEach { $0.close() }
        overlays.removeAll()
    }

    func toggleHUD() {
        if hud?.isVisible == true { hideHUD(); return }
        showHUD()
    }

    func showHUD() {
        guard hud?.isVisible != true else { return }
        let isNew = hud == nil
        let panel = hud ?? RestPanel(contentRect: NSRect(x: 0, y: 0, width: 276, height: 184),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud = panel
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hudDragEnabled = true
        panel.contentView = NSHostingView(rootView: RestHUDView(rest: rest, close: { [weak panel, weak rest] in
            panel?.close()
            rest?.setHUDVisible(false)
        }, wellness: wellness))
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let defaultOrigin = NSPoint(x: visible.maxX - 292, y: visible.midY - 92)
        if isNew {
            panel.setFrameAutosaveName("XStatsRestHUD")
            if !panel.setFrameUsingName("XStatsRestHUD") { panel.setFrameOrigin(defaultOrigin) }
        }
        // 旧版保存的窗口尺寸也要更新，保留用户位置，再限制到当前显示器可用范围。
        panel.setContentSize(NSSize(width: 276, height: 184))
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: min(max(panel.frame.minX, area.minX), area.maxX - panel.frame.width),
                                         y: min(max(panel.frame.minY, area.minY), area.maxY - panel.frame.height)))
        }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            panel.setFrameOrigin(defaultOrigin)
        }
        panel.orderFrontRegardless()
        rest.setHUDVisible(true)
    }

    func hideHUD() {
        hud?.close()
        rest.setHUDVisible(false)
    }

    private func refreshScreens() {
        if rest.phase.isResting && rest.isRunning || wellness?.isEyeRestActive == true { showRest() }
        if let hud, hud.isVisible {
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(hud.frame) }) {
                let visible = NSScreen.main?.visibleFrame ?? .zero
                hud.setFrameOrigin(NSPoint(x: visible.maxX - 292, y: visible.midY - 92))
            }
        }
    }
}
