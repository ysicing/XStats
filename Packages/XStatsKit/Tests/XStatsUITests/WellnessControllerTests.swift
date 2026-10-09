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
        var preferences = WellnessPreferences()
        preferences.breakEnabled = true
        preferences.waterEnabled = true
        settings.wellnessPreferences = preferences
        let clock = Clock()
        let base = Date(timeIntervalSince1970: 1_800_057_600)
        let rest = RestController(settings: settings, localDefaults: defaults, sharedDefaults: nil,
                                  clock: { UInt64(clock.seconds * 1e9) }, date: { base.addingTimeInterval(clock.seconds) })
        let wellness = WellnessController(rest: rest, settings: settings, store: WellnessActivityStore(url: nil),
                                          clock: { clock.seconds }, date: { base.addingTimeInterval(clock.seconds) },
                                          schedulesTimers: timers)
        rest.sync()
        wellness.sync()
        try await body(settings, rest, wellness, clock)
        rest.stop()
        await wellness.prepareForTermination()
    }

    @Test func remindersWorkWithoutPomodoroAndWaterOnlyCountsConfirmedActions() async throws {
        try await fixture { _, rest, wellness, clock in
            #expect(!rest.isRunning)
            clock.seconds = 3600
            wellness.refresh()
            await wellness.flush()
            #expect(wellness.pending == [.rest, .water])
            #expect(wellness.summary.today?.waterCount == 0)
            wellness.recordWater()
            await wellness.flush()
            #expect(wellness.summary.today?.waterCount == 1)
            wellness.undoWater()
            await wellness.flush()
            #expect(wellness.summary.today?.waterCount == 0)
        }
    }

    @Test func pomodoroBreakMergesAndSatisfiesRestWithoutDuplicatedNotifications() async throws {
        try await fixture { _, rest, wellness, clock in
            var notifications = 0
            wellness.onReminder = { _ in notifications += 1 }
            rest.setRunning(true)
            clock.seconds = 1500
            rest.sync()
            #expect(rest.phase == .rest)
            #expect(wellness.pending == [.rest])
            #expect(notifications == 0)
            clock.seconds = 1800
            rest.sync()
            await wellness.flush()
            #expect(!wellness.pending.contains(.rest))
            #expect(wellness.summary.today?.restSeconds == 300)
            #expect(wellness.summary.today?.focusSeconds == 1500)
        }
    }

    @Test func endingFocusDuringAnIndependentExerciseDoesNotOfferToResumeAnEndedSession() async throws {
        try await fixture { _, rest, wellness, clock in
            rest.setRunning(true)
            clock.seconds = 10
            wellness.startBreathing()
            #expect(wellness.canContinueFocus)
            rest.endSession()
            #expect(!wellness.canContinueFocus && wellness.activeExercise == .breathing)
            clock.seconds = 190
            wellness.refresh()
            await wellness.flush()
            #expect(wellness.activeExercise == nil && !wellness.canContinueFocus)
            #expect(wellness.summary.today?.focusSeconds == 10)
        }
    }

    @Test func voluntaryBreathingPausesFocusAndResumesOnlyWhenAsked() async throws {
        try await fixture { _, rest, wellness, clock in
            rest.setRunning(true)
            clock.seconds = 20
            wellness.startBreathing()
            #expect(!rest.isRunning && wellness.activeExercise == .breathing)
            clock.seconds = 200
            wellness.refresh()
            await wellness.flush()
            #expect(wellness.activeExercise == nil && !rest.isRunning)
            #expect(wellness.canContinueFocus)
            #expect(wellness.summary.today?.focusSeconds == 20)
            #expect(wellness.summary.today?.breathingSeconds == 180)
            #expect(wellness.summary.today?.restSeconds == 180)
            wellness.continueFocus()
            #expect(rest.isRunning && rest.secondsRemaining == 1480)
        }
    }

    @Test func breathingWithinPomodoroRestIsASubsetAndDoesNotExtendTheBreak() async throws {
        try await fixture { _, rest, wellness, clock in
            rest.setRunning(true)
            clock.seconds = 1500
            rest.sync()
            clock.seconds = 1680
            wellness.startBreathing()
            #expect(wellness.exerciseSecondsRemaining == 120)
            #expect(wellness.exerciseDuration == 120)
            clock.seconds = 1800
            rest.sync()
            await wellness.flush()
            #expect(wellness.activeExercise == nil)
            #expect(wellness.summary.today?.breathingSeconds == 120)
            #expect(wellness.summary.today?.restSeconds == 300)
        }
    }

    @Test func eyeRestProgressUsesActualDurationAndSurvivesPreferenceAndHistoryChanges() async throws {
        try await fixture { settings, rest, wellness, clock in
            rest.setRunning(true)
            clock.seconds = 1500
            rest.sync()
            clock.seconds = 1780
            wellness.startShortRest()
            #expect(wellness.exerciseDuration == 20)
            #expect(wellness.exerciseSecondsRemaining == 20)
            clock.seconds = 1790
            settings.wellnessPreferences.breakSeconds = 180
            wellness.clearHistory()
            wellness.refresh()
            #expect(wellness.exerciseDuration == 20)
            #expect(wellness.exerciseSecondsRemaining == 10)
            wellness.finishExercise(completed: false)
            #expect(wellness.exerciseDuration == 0)
            wellness.startShortRest()
            #expect(wellness.exerciseDuration == 10)
        }
    }

    @Test func disablingAndSuspendingRemoveWakeupsAndDiscardLateExerciseCompletion() async throws {
        try await fixture { settings, _, wellness, clock in
            wellness.startBreathing()
            clock.seconds = 10
            wellness.suspend()
            #expect(wellness.nextWake == nil && wellness.activeExercise == nil)
            clock.seconds = 10000
            wellness.resume()
            #expect(wellness.pending.isEmpty)
            #expect(wellness.nextWake == 11790)
            settings.restEnabled = false
            wellness.sync()
            #expect(wellness.nextWake == nil)
        }
    }
    @Test func activeClearDoesNotBringBackTimeRecordedBeforeClear() async throws {
        try await fixture { _, rest, wellness, clock in
            rest.setRunning(true)
            clock.seconds = 100
            wellness.clearHistory()
            clock.seconds = 110
            rest.setRunning(false)
            await wellness.flush()
            #expect(wellness.summary.today?.focusSeconds == 10)
            wellness.startBreathing()
            clock.seconds = 120
            wellness.clearHistory()
            clock.seconds = 130
            wellness.finishExercise(completed: false)
            await wellness.flush()
            #expect(wellness.summary.today?.focusSeconds == 0)
            #expect(wellness.summary.today?.breathingSeconds == 10)
        }
    }

    @Test func pausedBreathingDoesNotCreditWaitingTime() async throws {
        try await fixture { _, _, wellness, clock in
            wellness.startBreathing()
            clock.seconds = 10
            wellness.toggleBreathingPause()
            let expansion = wellness.breathingReading?.expansion
            clock.seconds = 100
            wellness.refresh()
            #expect(wellness.exerciseSecondsRemaining == 170)
            #expect(wellness.breathingReading?.expansion == expansion)
            wellness.toggleBreathingPause()
            clock.seconds = 110
            wellness.finishExercise(completed: false)
            await wellness.flush()
            #expect(wellness.summary.today?.breathingSeconds == 20)
        }
    }

    @Test func repeatedExerciseTogglesReleaseCountdownAndMasterOffReleasesAllTimers() async throws {
        try await fixture(timers: true) { settings, _, wellness, _ in
            #expect(wellness.hasDeadlineTimer && !wellness.hasDisplayTimer)
            for _ in 0..<20 {
                wellness.startBreathing()
                #expect(wellness.hasDisplayTimer)
                wellness.toggleBreathingPause()
                #expect(!wellness.hasDisplayTimer)
                wellness.finishExercise(completed: false)
                #expect(!wellness.hasDisplayTimer)
            }
            wellness.suspend()
            #expect(!wellness.hasDeadlineTimer && !wellness.hasDisplayTimer)
            wellness.resume()
            #expect(wellness.hasDeadlineTimer && !wellness.hasDisplayTimer)
            settings.wellnessPreferences.breakEnabled = false
            settings.wellnessPreferences.waterEnabled = false
            wellness.sync()
            #expect(!wellness.hasDeadlineTimer && !wellness.hasDisplayTimer)
            wellness.startShortRest()
            #expect(wellness.hasDisplayTimer)
            settings.restEnabled = false
            wellness.sync()
            #expect(!wellness.hasDeadlineTimer && !wellness.hasDisplayTimer)
        }
    }

}
