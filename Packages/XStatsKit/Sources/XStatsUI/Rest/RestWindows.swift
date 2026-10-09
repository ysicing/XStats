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
        guard point.y > 44 else { return false }
        let inHeader = point.y >= frame.height - 42
        let overActionButtons = L10n.language.isRightToLeft ? point.x < 60 : point.x > frame.width - 60
        return !inHeader || !overActionButtons
    }
}

private struct RestOverlayContent: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let rest: RestController
    let wellness: WellnessController?

    var body: some View {
        ZStack {
            if let wellness, wellness.activeExercise != nil {
                if reduceTransparency { Color(nsColor: .windowBackgroundColor) } else { Color.black.opacity(0.25) }
                WellnessExerciseView(wellness: wellness)
            } else {
                VStack(spacing: DS.Space.s4) {
                    RestOverlayView(rest: rest)
                    if let wellness, !wellness.pending.isEmpty {
                        HStack(spacing: DS.Space.s3) {
                            if wellness.pending.contains(.water) {
                                Button(tr("已喝水")) { wellness.recordWater() }
                                    .buttonStyle(DSButtonStyle(kind: .secondary))
                            }
                            Button(tr("呼吸练习")) { wellness.startBreathing() }
                                .buttonStyle(DSButtonStyle(kind: .secondary))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RestOverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let rest: RestController
    @State private var breathing = false
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
                                  haloScale: breathing && !reduceMotion ? 1.12 : 0.9)
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
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) { breathing = true }
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

private struct RestHUDView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let rest: RestController
    let close: () -> Void
    var wellness: WellnessController? = nil

    var body: some View {
        let language = rest.settings.language.resolved
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label(wellness?.activeExercise == .breathing ? tr("呼吸练习") : wellness?.activeExercise == .rest ? tr("休息") : rest.phase.title,
                      systemImage: wellness?.activeExercise == .breathing ? "wind" : rest.phase.isResting ? "eye" : "timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(rest.phase.isResting ? .green : .orange)
                Spacer(minLength: 0)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 20)
                    .help(tr("拖动迷你 HUD"))
                Button {
                    rest.settings.restHUDStyle = rest.settings.restHUDStyle.next
                } label: {
                    Image(systemName: rest.settings.restHUDStyle.symbol)
                }
                .buttonStyle(.plain)
                .help(tr("切换迷你 HUD 样式"))
                .accessibilityLabel(tr("切换迷你 HUD 样式"))
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(tr("收起迷你 HUD"))
            }
            display
                .frame(maxWidth: .infinity)
                .frame(height: 76)
            HStack(spacing: 20) {
                if let wellness, wellness.activeExercise != nil {
                    if wellness.activeExercise == .breathing {
                        Button { wellness.toggleBreathingPause() } label: {
                            Image(systemName: wellness.isExerciseRunning ? "pause.fill" : "play.fill")
                        }.help(tr(wellness.isExerciseRunning ? "暂停" : "继续"))
                    }
                    Button { wellness.finishExercise(completed: false) } label: { Image(systemName: "stop.fill") }
                        .help(tr("结束练习"))
                } else {
                    Button { rest.startPause() } label: {
                        Image(systemName: rest.isRunning ? "pause.fill" : "play.fill").frame(width: 16)
                    }
                    .help(rest.primaryAction.title)
                    Button { rest.endSession() } label: { Image(systemName: "stop.fill").frame(width: 16) }
                        .help(tr("结束")).disabled(!rest.canEndSession)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 250, height: 160)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .windowBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: 18).fill(.regularMaterial)
            }
        }
        .environment(\.locale, L10n.locale(for: language))
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    @ViewBuilder
    private var display: some View {
        let progress = rest.phaseDuration > 0
            ? min(1, max(0, 1 - rest.secondsRemaining / rest.phaseDuration)) : 0
        let tint: Color = rest.phase.isResting ? .green : .orange
        let clock = String(format: "%02d:%02d", max(0, Int(rest.secondsRemaining.rounded(.up))) / 60,
                           max(0, Int(rest.secondsRemaining.rounded(.up))) % 60)

        if let wellness, wellness.activeExercise != nil {
            Text(WellnessFormat.timer(wellness.exerciseSecondsRemaining))
                .font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
        } else {
            switch rest.settings.restHUDStyle {
            case .countdown:
                Text(clock)
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .monospacedDigit()
            case .ring:
                ZStack {
                    Circle().stroke(tint.opacity(0.18), lineWidth: 5)
                    Circle().trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(clock).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 72, height: 72)
            case .hourglass:
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 42, weight: .ultraLight))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tint)
                            .accessibilityHidden(true)
                        Text(clock)
                            .font(.system(size: 19, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(tint.opacity(0.14))
                            Capsule().fill(tint)
                                .frame(width: geometry.size.width * (1 - progress))
                        }
                    }
                    .frame(width: 142, height: 4)
                }
            }
        }
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
                if wellness?.activeExercise != nil { wellness?.finishExercise(completed: false) }
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
        let panel = hud ?? RestPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 160),
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
        let defaultOrigin = NSPoint(x: visible.maxX - 266, y: visible.midY - 80)
        if isNew {
            panel.setFrameAutosaveName("XStatsRestHUD")
            if !panel.setFrameUsingName("XStatsRestHUD") { panel.setFrameOrigin(defaultOrigin) }
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
        if rest.phase.isResting && rest.isRunning || wellness?.activeExercise != nil { showRest() }
        if let hud, hud.isVisible {
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(hud.frame) }) {
                let visible = NSScreen.main?.visibleFrame ?? .zero
                hud.setFrameOrigin(NSPoint(x: visible.maxX - 266, y: visible.midY - 80))
            }
        }
    }
}
