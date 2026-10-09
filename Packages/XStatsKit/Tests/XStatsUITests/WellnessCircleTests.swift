// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import XStatsUI

@MainActor struct WellnessCircleTests {
    @Test func nativeAnimationStopsOnPauseReducedMotionAndDismantle() {
        let view = WellnessBreathingCircle.CircleView()
        view.frame = NSRect(x: 0, y: 0, width: 210, height: 210)
        let session = BreathingSession(now: 0, duration: 180, pattern: .gentle)
        view.update(reading: session.reading(at: 1), running: true, reduceMotion: false)
        #expect(view.hasAnimation)
        view.update(reading: session.reading(at: 2), running: false, reduceMotion: false)
        #expect(!view.hasAnimation)
        view.update(reading: session.reading(at: 2), running: true, reduceMotion: false)
        #expect(view.hasAnimation)
        view.update(reading: session.reading(at: 2), running: true, reduceMotion: true)
        #expect(!view.hasAnimation)
        view.update(reading: session.reading(at: 4), running: true, reduceMotion: false)
        #expect(view.hasAnimation)
        view.stop()
        #expect(!view.hasAnimation)
        view.update(reading: nil, running: false, reduceMotion: false)
        #expect(!view.hasAnimation)
    }
}
