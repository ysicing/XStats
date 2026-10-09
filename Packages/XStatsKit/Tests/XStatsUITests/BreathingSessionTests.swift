// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import XStatsUI

struct BreathingSessionTests {
    @Test func gentlePatternHasNoForcedHoldAndUsesAbsoluteTime() {
        let session = BreathingSession(now: 0, duration: 180, pattern: .gentle)
        #expect(session.reading(at: 0).phase == .inhale)
        #expect(session.reading(at: 4).phase == .exhale)
        #expect(session.reading(at: 10).phase == .inhale)
        #expect(session.reading(at: 65).secondsRemaining == 115)
    }

    @Test func pauseAndResumeKeepThePresentationAndRemainingTime() {
        var session = BreathingSession(now: 100, duration: 180, pattern: .gentle)
        let before = session.reading(at: 102)
        session.pause(at: 102)
        #expect(session.reading(at: 1000) == before)
        session.resume(at: 1000)
        #expect(session.reading(at: 1000) == before)
        #expect(session.reading(at: 1002).phase == .exhale)
        #expect(session.reading(at: 1178).isFinished)
        #expect(session.reading(at: 1178).secondsRemaining == 0)
    }

    @Test func eachPatternAdvancesPastHoldsAndCompletionNeverResetsTheClock() {
        let box = BreathingSession(now: 0, duration: 60, pattern: .box)
        #expect(box.reading(at: 4).phase == .hold)
        #expect(box.reading(at: 8).phase == .exhale)
        #expect(box.reading(at: 12).phase == .hold)
        let relax = BreathingSession(now: 0, duration: 60, pattern: .relax)
        #expect(relax.reading(at: 4).phase == .hold)
        #expect(relax.reading(at: 11).phase == .exhale)
        #expect(relax.reading(at: 60).isFinished)
        #expect(relax.reading(at: 90).isFinished)
    }
}
