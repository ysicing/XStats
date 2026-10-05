// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
@testable import AudioControl
struct AudioRenderHealthTests {
    @Test func allowsOneRetryThenReleasesAPathThatNeverRenders() {
        var health = AudioRenderHealth(now: 10)
        #expect(health.observe(frames: 0, now: 11) == .wait)
        #expect(health.observe(frames: 0, now: 11.5) == .retry)
        health.restarted(now: 12)
        #expect(health.observe(frames: 0, now: 13.4) == .wait)
        #expect(health.observe(frames: 0, now: 13.5) == .release)
    }
    @Test func renderedProgressResetsTheFailureBudget() {
        var health = AudioRenderHealth(now: 0)
        #expect(health.observe(frames: 0, now: 1.5) == .retry)
        health.restarted(now: 2)
        #expect(health.observe(frames: 480, now: 2.5) == .wait)
        #expect(health.observe(frames: 480, now: 4) == .retry)
    }
}
