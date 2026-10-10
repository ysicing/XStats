// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor struct WellnessControllerTests {
    @MainActor private final class Clock { var seconds: TimeInterval = 0 }
    private func fixture(timers: Bool = false, _ body: (AppSettings, RestController, WellnessController, Clock) async throws -> Void) async throws {
        let name = "WellnessControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        settings.wellnessPreferences.breakEnabled = true
        let clock = Clock()
        let base = Date(timeIntervalSince1970: 1_800_057_600)
        let rest = RestController(settings: settings, localDefaults: defaults, sharedDefaults: nil,
                                  clock: { UInt64(clock.seconds * 1e9) }, date: { base.addingTimeInterval(clock.seconds) })
        let wellness = WellnessController(rest: rest, settings: settings, store: WellnessActivityStore(url: nil),
                                          clock: { clock.seconds }, date: { base.addingTimeInterval(clock.seconds) }, schedulesTimers: timers)
        rest.sync(); wellness.sync()
        try await body(settings, rest, wellness, clock)
        rest.stop(); await wellness.prepareForTermination()
    }

    @Test func eyeReminderWorksWithoutPomodoroAndCompletedEyeRestResetsIt() async throws {
        try await fixture { _, rest, wellness, clock in
            #expect(!rest.isRunning)
            clock.seconds = 1800; wellness.refresh()
            #expect(wellness.pending == [.rest])
            wellness.startShortRest()
            clock.seconds += 60; wellness.refresh(); await wellness.flush()
            #expect(!wellness.isEyeRestActive && wellness.pending.isEmpty)
            #expect(wellness.summary.today?.restSeconds == 60)
            #expect(wellness.nextWake == clock.seconds + 1800)
        }
    }

    @Test func repeatedEyeRestRequestsKeepDeadlineAndRespectDisabledFeature() async throws {
        try await fixture { settings, _, wellness, clock in
            wellness.startShortRest()
            #expect(wellness.isEyeRestActive)
            clock.seconds = 30
            wellness.startShortRest()
            wellness.refresh()
            #expect(wellness.eyeRestSecondsRemaining == 30)
            clock.seconds = 60
            wellness.refresh()
            #expect(!wellness.isEyeRestActive)
            settings.restEnabled = false
            wellness.sync()
            wellness.startShortRest()
            #expect(!wellness.isEyeRestActive)
        }
    }

    @Test func pomodoroBreakMergesAndSatisfiesReminderWithoutDuplicateTime() async throws {
        try await fixture { _, rest, wellness, clock in
            var notifications = 0
            wellness.onReminder = { _ in notifications += 1 }
            rest.setRunning(true)
            clock.seconds = 1500; rest.sync()
            #expect(wellness.pending == [.rest] && notifications == 0)
            clock.seconds = 1680; wellness.startShortRest()
            #expect(wellness.eyeRestDuration == 60)
            clock.seconds = 1740; wellness.refresh()
            clock.seconds = 1800; rest.sync(); await wellness.flush()
            #expect(wellness.pending.isEmpty && !wellness.isEyeRestActive)
            #expect(wellness.summary.today?.focusSeconds == 1500)
            #expect(wellness.summary.today?.restSeconds == 300)
        }
    }

    @Test func eyeRestPausesFocusAndUserExplicitlyResumes() async throws {
        try await fixture { _, rest, wellness, clock in
            rest.setRunning(true); clock.seconds = 20; wellness.startShortRest()
            #expect(!rest.isRunning && wellness.isEyeRestActive)
            clock.seconds = 80; wellness.refresh(); await wellness.flush()
            #expect(!rest.isRunning && wellness.canContinueFocus && !wellness.isEyeRestActive)
            #expect(wellness.summary.today?.focusSeconds == 20 && wellness.summary.today?.restSeconds == 60)
            wellness.continueFocus()
            #expect(rest.isRunning && rest.secondsRemaining == 1480)
        }
    }

    @Test func eyeRestDurationStaysFixedAndClearStartsANewSegment() async throws {
        try await fixture { settings, _, wellness, clock in
            settings.wellnessPreferences.breakSeconds = 120; wellness.sync(); wellness.startShortRest()
            clock.seconds = 10; wellness.refresh()
            settings.wellnessPreferences.breakSeconds = 20; wellness.sync()
            #expect(wellness.eyeRestDuration == 120 && wellness.eyeRestSecondsRemaining == 110)
            wellness.clearHistory(); clock.seconds = 30; wellness.finishEyeRest(completed: false)
            await wellness.flush()
            #expect(wellness.summary.today?.restSeconds == 20)
        }
    }

    @Test func endingFocusWhileRestingClearsResumeAction() async throws {
        try await fixture { _, rest, wellness, clock in
            rest.setRunning(true); clock.seconds = 10; wellness.startShortRest()
            rest.endSession()
            #expect(!wellness.canContinueFocus && wellness.isEyeRestActive)
            clock.seconds = 70; wellness.refresh()
            #expect(!wellness.isEyeRestActive && !wellness.canContinueFocus)
        }
    }

    @Test func suspendAndDisableReleaseTimersAndDoNotCountSleep() async throws {
        try await fixture(timers: true) { settings, _, wellness, clock in
            #expect(wellness.hasDeadlineTimer && !wellness.hasDisplayTimer)
            for _ in 0..<20 {
                wellness.startShortRest(); #expect(wellness.hasDisplayTimer)
                wellness.finishEyeRest(completed: false); #expect(!wellness.hasDisplayTimer)
            }
            wellness.startShortRest(); clock.seconds = 10; wellness.suspend()
            #expect(!wellness.hasDeadlineTimer && !wellness.hasDisplayTimer && !wellness.isEyeRestActive)
            clock.seconds = 10000; wellness.resume(); await wellness.flush()
            #expect(wellness.pending.isEmpty && wellness.nextWake == 11790)
            #expect(wellness.summary.today?.restSeconds == 10)
            settings.wellnessPreferences.breakEnabled = false; wellness.sync()
            #expect(!wellness.hasDeadlineTimer)
            wellness.startShortRest(); settings.restEnabled = false; wellness.sync()
            #expect(!wellness.isEyeRestActive && !wellness.hasDisplayTimer && !wellness.hasDeadlineTimer)
        }
    }
}
