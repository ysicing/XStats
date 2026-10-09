// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import QuartzCore
import SwiftUI

/// SwiftUI 只传入时钟状态，系统图层插值；每个阶段一次更新，不逐帧重建视图。
struct WellnessBreathingCircle: NSViewRepresentable {
    let reading: BreathingReading?
    let running: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> CircleView { CircleView() }
    func updateNSView(_ view: CircleView, context: Context) {
        view.update(reading: reading, running: running, reduceMotion: reduceMotion)
    }
    static func dismantleNSView(_ view: CircleView, coordinator: ()) { view.stop() }

    @MainActor final class CircleView: NSView {
        private let circle = CAShapeLayer()
        private var lastReading: BreathingReading?
        private var lastRunning = false
        private var lastReduced = false

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(circle)
            circle.lineWidth = 3
            updateColors()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            circle.bounds = CGRect(origin: .zero, size: bounds.size)
            circle.position = CGPoint(x: bounds.midX, y: bounds.midY)
            circle.path = CGPath(ellipseIn: circle.bounds.insetBy(dx: 2, dy: 2), transform: nil)
            CATransaction.commit()
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stop() } }

        private func updateColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                circle.fillColor = NSColor.systemTeal.withAlphaComponent(0.08).cgColor
                circle.strokeColor = NSColor.systemTeal.withAlphaComponent(0.4).cgColor
            }
        }

        func update(reading: BreathingReading?, running: Bool, reduceMotion: Bool) {
            let phaseChanged = lastReading?.phase != reading?.phase || lastReading?.expanded != reading?.expanded
                || lastReading?.phaseDuration != reading?.phaseDuration
                || (reading?.phaseProgress ?? 0) < (lastReading?.phaseProgress ?? 0)
            defer { lastReading = reading; lastRunning = running; lastReduced = reduceMotion }
            guard phaseChanged || lastRunning != running || lastReduced != reduceMotion || lastReading == nil else { return }
            let progress = DS.Motion.breathingProgress(reading?.phaseProgress ?? 0.5)
            let expansion: Double
            switch reading?.phase {
            case .inhale: expansion = progress
            case .exhale: expansion = 1 - progress
            case .hold: expansion = reading?.expanded == true ? 1 : 0
            case nil: expansion = 0.5
            }
            let scale = reduceMotion ? 0.88 : 0.72 + expansion * 0.28
            CATransaction.begin(); CATransaction.setDisableActions(true)
            circle.removeAnimation(forKey: "breathing")
            circle.transform = CATransform3DMakeScale(scale, scale, 1)
            CATransaction.commit()
            guard let reading, running, !reduceMotion, !reading.isFinished, reading.phase != .hold else { return }
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = reading.phase == .inhale ? 0.72 : 1.0
            animation.toValue = reading.phase == .inhale ? 1.0 : 0.72
            animation.duration = reading.phaseDuration
            animation.timingFunction = DS.Motion.breathingTimingFunction
            // 源时钟决定相位；暂停/恢复从相同位置继续，不重新跑一遍完整吸气/呼气。
            animation.beginTime = circle.convertTime(CACurrentMediaTime(), from: nil) - reading.phaseProgress * reading.phaseDuration
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            circle.add(animation, forKey: "breathing")
        }

        func stop() { circle.removeAllAnimations() }
        var hasAnimation: Bool { circle.animation(forKey: "breathing") != nil }
    }
}
