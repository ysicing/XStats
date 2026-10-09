// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

/// 迷你计时窗口：时间是主视觉，颜色只标记阶段和进度；隐藏后不创建任何刷新任务。
struct RestHUDView: View {
    let rest: RestController
    let close: () -> Void
    var wellness: WellnessController? = nil

    private var eyeRest: Bool { wellness?.isEyeRestActive == true }
    private var seconds: TimeInterval { eyeRest ? wellness?.eyeRestSecondsRemaining ?? 0 : rest.secondsRemaining }
    private var duration: TimeInterval { eyeRest ? wellness?.eyeRestDuration ?? 0 : rest.phaseDuration }
    private var progress: Double { duration > 0 ? min(1, max(0, 1 - seconds / duration)) : 0 }
    private var resting: Bool { eyeRest || rest.phase.isResting }
    private var accent: Color { resting ? DS.Palette.success : DS.Palette.warning }
    private var running: Bool { eyeRest || rest.isRunning }
    private var status: String { tr(running ? "计时中" : rest.primaryAction == .resume ? "已暂停" : "待开始") }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                    .buttonStyle(RestHUDButtonStyle(size: 24))
                    .help(tr("收起迷你 HUD")).accessibilityLabel(tr("收起迷你 HUD"))
                Label(eyeRest ? tr("护眼休息") : rest.phase.title, systemImage: resting ? "eye" : "timer")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { rest.settings.restHUDStyle = rest.settings.restHUDStyle.next } label: {
                    Image(systemName: rest.settings.restHUDStyle.symbol).font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(RestHUDButtonStyle(size: 24))
                .help(tr("切换迷你 HUD 样式")).accessibilityLabel(tr("切换迷你 HUD 样式"))
            }
            .frame(height: 24)
            display.frame(maxWidth: .infinity).frame(height: 68)
            HStack(spacing: 8) {
                Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !eyeRest {
                    Button { rest.startPause() } label: {
                        Image(systemName: running ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(RestHUDButtonStyle(size: 32, primary: true))
                    .help(rest.primaryAction.title).accessibilityLabel(rest.primaryAction.title)
                }
                Button {
                    if eyeRest { wellness?.finishEyeRest(completed: false) }
                    else { rest.endSession() }
                } label: { Image(systemName: "stop.fill").font(.system(size: 10, weight: .medium)) }
                .buttonStyle(RestHUDButtonStyle(size: 32))
                .help(tr("结束")).accessibilityLabel(tr("结束"))
                .disabled(!eyeRest && !rest.canEndSession)
            }
            .frame(height: 32)
        }
        .padding(16).frame(width: 276, height: 184)
        .modifier(RestHUDSurface())
        .environment(\.locale, L10n.locale(for: rest.settings.language.resolved))
        .environment(\.layoutDirection, rest.settings.language.resolved.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    @ViewBuilder private var display: some View {
        switch rest.settings.restHUDStyle {
        case .countdown:
            clock(size: 48)
        case .ring:
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(accent.opacity(0.14), lineWidth: 4)
                    Circle().trim(from: 0, to: progress)
                        .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: resting ? "eye" : "timer").font(.system(size: 18, weight: .regular))
                        .foregroundStyle(accent)
                }.frame(width: 48, height: 48).accessibilityHidden(true)
                clock(size: 38)
            }
        case .hourglass:
            VStack(spacing: 10) {
                clock(size: 44)
                remainingBar
            }
        }
    }

    private func clock(size: CGFloat) -> some View {
        Text(WellnessFormat.timer(seconds))
            .font(.system(size: size, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
    }

    private var remainingBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.12))
                Capsule().fill(accent.opacity(0.8)).frame(width: geometry.size.width * (1 - progress))
            }
        }.frame(width: 188, height: 3).accessibilityHidden(true)
    }
}

/// 浮窗用系统材质适应桌面；不叠实色遮罩，也不在容器内再叠按钮玻璃。
private struct RestHUDSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
        if reduceTransparency || isSnapshot {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            content.environment(\.isInsideGlass, true).dsGlass(in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(DS.Palette.border.opacity(0.7), lineWidth: 0.5))
        }
    }
}

/// 高频计时操作即时反馈；固定点击区域避免暂停/继续图标改变时按钮移动。
private struct RestHUDButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    let size: CGFloat
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background(primary ? DS.Palette.primary : DS.Palette.textPrimary.opacity(configuration.isPressed ? 0.12 : 0.055), in: Circle())
            .opacity(enabled ? configuration.isPressed ? 0.72 : hovering ? 0.88 : 1 : 0.35)
            .onHover { hovering = $0 }
            .contentShape(Circle())
    }
}
