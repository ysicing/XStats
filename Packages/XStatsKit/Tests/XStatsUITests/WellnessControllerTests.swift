// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Testing
@testable import XStatsUI

@MainActor struct WellnessControllerTests {
  @MainActor private final class Clock { var seconds: TimeInterval = 0 }
  private func fixture(
    timers: Bool = false,
    _ body: (AppSettings, RestController, WellnessController, Clock) async throws -> Void
  ) async throws {
    let name = "WellnessControllerTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    settings.restEnabled = true
    settings.wellnessPreferences.breakEnabled = true
    let clock = Clock()
    let base = Date(timeIntervalSince1970: 1_800_057_600)
    let rest = RestController(
      settings: settings, localDefaults: defaults, sharedDefaults: nil,
      clock: { UInt64(clock.seconds * 1e9) }, date: { base.addingTimeInterval(clock.seconds) })
    let wellness = WellnessController(
      rest: rest, settings: settings, store: WellnessActivityStore(url: nil),
      clock: { clock.seconds }, date: { base.addingTimeInterval(clock.seconds) },
      schedulesTimers: timers)
    rest.sync()
    wellness.sync()
    try await body(settings, rest, wellness, clock)
    rest.stop()
    await wellness.prepareForTermination()
  }

  @Test func cancellingTimerConflictKeepsResumeFocusAfterEyeBreak() async throws {
    try await fixture { settings, rest, wellness, clock in
      let timer = TimerController(rest: rest, settings: settings, clock: { clock.seconds })
      defer { timer.stop() }
      rest.startPause()
      clock.seconds += 10
      wellness.startShortRest()
      wellness.finishEyeRest(completed: false)
      #expect(wellness.canContinueFocus)
      timer.startPauseCountdown()
      wellness.continueFocus()
      #expect(timer.pendingStart == .pomodoro)
      timer.cancelSwitch()
      #expect(wellness.canContinueFocus)
      #expect(rest.isRunning == false)
      wellness.continueFocus()
      timer.confirmSwitch()
      #expect(rest.isRunning)
      #expect(wellness.canContinueFocus == false)
    }
  }

  @Test func eyeReminderWorksWithoutPomodoroAndCompletedEyeRestResetsIt() async throws {
    try await fixture { _, rest, wellness, clock in
      #expect(!rest.isRunning)
      clock.seconds = 1800
      wellness.refresh()
      #expect(wellness.pending == [.rest])
      wellness.startShortRest()
      clock.seconds += 60
      wellness.refresh()
      await wellness.flush()
      #expect(!wellness.isEyeRestActive && wellness.pending.isEmpty)
      #expect(wellness.summary.today?.restSeconds == 60)
      #expect(wellness.nextWake == clock.seconds + 1800)
    }
  }

  @Test func timerReminderStatusKeepsScheduledTimeAndDistinguishesSuspension() async throws {
    try await fixture { settings, _, wellness, _ in
      let deadline = try #require(wellness.nextRestAt)
      #expect(TimerReminderStatus(wellness: wellness) == .scheduled(deadline))
      wellness.suspend()
      #expect(TimerReminderStatus(wellness: wellness) == .paused)
      wellness.resume()
      #expect(TimerReminderStatus(wellness: wellness) == .scheduled(deadline))
      settings.wellnessPreferences.breakEnabled = false
      wellness.sync()
      #expect(TimerReminderStatus(wellness: wellness) == .disabled)
    }
  }

  @Test func timerReminderStatusPrioritizesActiveBreakOverDisabledReminders() async throws {
    try await fixture { settings, _, wellness, _ in
      settings.wellnessPreferences.breakEnabled = false
      wellness.sync()
      wellness.startBreak(.short)
      #expect(TimerReminderStatus(wellness: wellness) == .resting)
      wellness.suspend(preservingRest: true)
      #expect(TimerReminderStatus(wellness: wellness) == .resting)
      wellness.finishEyeRest(completed: false)
      #expect(TimerReminderStatus(wellness: wellness) == .disabled)
    }
  }

  @Test func timerReminderStatusDistinguishesDueAndPostponedReminders() async throws {
    try await fixture { _, _, wellness, clock in
      clock.seconds = 1800
      wellness.refresh()
      #expect(TimerReminderStatus(wellness: wellness) == .pending)
      wellness.postpone(.rest)
      let deadline = try #require(wellness.nextRestAt)
      #expect(TimerReminderStatus(wellness: wellness) == .scheduled(deadline))
      #expect(wellness.pending.isEmpty)
      wellness.suspend()
      #expect(TimerReminderStatus(wellness: wellness) == .paused)
      wellness.resume()
      #expect(TimerReminderStatus(wellness: wellness) == .scheduled(deadline))
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
      clock.seconds = 1500
      rest.sync()
      #expect(wellness.pending == [.rest] && notifications == 0)
      clock.seconds = 1680
      wellness.startShortRest()
      #expect(wellness.eyeRestDuration == 60)
      clock.seconds = 1740
      wellness.refresh()
      clock.seconds = 1800
      rest.sync()
      await wellness.flush()
      #expect(wellness.pending.isEmpty && !wellness.isEyeRestActive)
      #expect(wellness.summary.today?.focusSeconds == 1500)
      #expect(wellness.summary.today?.restSeconds == 300)
    }
  }

  @Test func eyeRestPausesFocusAndUserExplicitlyResumes() async throws {
    try await fixture { _, rest, wellness, clock in
      rest.setRunning(true)
      clock.seconds = 20
      wellness.startShortRest()
      #expect(!rest.isRunning && wellness.isEyeRestActive)
      clock.seconds = 80
      wellness.refresh()
      await wellness.flush()
      #expect(!rest.isRunning && wellness.canContinueFocus && !wellness.isEyeRestActive)
      #expect(
        wellness.summary.today?.focusSeconds == 20 && wellness.summary.today?.restSeconds == 60)
      wellness.continueFocus()
      #expect(rest.isRunning && rest.secondsRemaining == 1480)
    }
  }

  @Test func eyeRestDurationStaysFixedAndClearStartsANewSegment() async throws {
    try await fixture { settings, _, wellness, clock in
      settings.wellnessPreferences.breakSeconds = 120
      wellness.sync()
      wellness.startShortRest()
      clock.seconds = 10
      wellness.refresh()
      settings.wellnessPreferences.breakSeconds = 20
      wellness.sync()
      #expect(wellness.eyeRestDuration == 120 && wellness.eyeRestSecondsRemaining == 110)
      wellness.clearHistory()
      clock.seconds = 30
      wellness.finishEyeRest(completed: false)
      await wellness.flush()
      #expect(wellness.summary.today?.restSeconds == 20)
    }
  }

  @Test func endingFocusWhileRestingClearsResumeAction() async throws {
    try await fixture { _, rest, wellness, clock in
      rest.setRunning(true)
      clock.seconds = 10
      wellness.startShortRest()
      rest.endSession()
      #expect(!wellness.canContinueFocus && wellness.isEyeRestActive)
      clock.seconds = 70
      wellness.refresh()
      #expect(!wellness.isEyeRestActive && !wellness.canContinueFocus)
    }
  }

  @Test func suspendAndDisableReleaseTimersAndDoNotCountSleep() async throws {
    try await fixture(timers: true) { settings, _, wellness, clock in
      #expect(wellness.hasDeadlineTimer && !wellness.hasDisplayTimer)
      for _ in 0..<20 {
        wellness.startShortRest()
        #expect(wellness.hasDisplayTimer)
        wellness.finishEyeRest(completed: false)
        #expect(!wellness.hasDisplayTimer)
      }
      wellness.startShortRest()
      clock.seconds = 10
      wellness.suspend()
      #expect(!wellness.hasDeadlineTimer && !wellness.hasDisplayTimer && !wellness.isEyeRestActive)
      clock.seconds = 10000
      wellness.resume()
      await wellness.flush()
      #expect(wellness.pending.isEmpty && wellness.nextWake == 11790)
      #expect(wellness.summary.today?.restSeconds == 10)
      settings.wellnessPreferences.breakEnabled = false
      wellness.sync()
      #expect(!wellness.hasDeadlineTimer)
      wellness.startShortRest()
      settings.restEnabled = false
      wellness.sync()
      #expect(!wellness.isEyeRestActive && !wellness.hasDisplayTimer && !wellness.hasDeadlineTimer)
    }
  }
  @Test func manualBreaksPreserveFocusAndIndependentTimers() async throws {
    try await fixture { settings, rest, wellness, clock in
      let timer = TimerController(rest: rest, settings: settings, clock: { clock.seconds })
      defer { timer.stop() }
      rest.setRunning(true)
      clock.seconds = 20
      let rounds = rest.completedRounds
      wellness.startBreak(.long)
      #expect(wellness.breakKind == .long)
      #expect(wellness.eyeRestDuration == Double(settings.restLongBreakMinutes * 60))
      #expect(!rest.isRunning && wellness.canContinueFocus)
      timer.startPauseCountdown()
      timer.startPauseStopwatch()
      clock.seconds += wellness.eyeRestDuration
      wellness.refresh()
      #expect(!wellness.isEyeRestActive && !rest.isRunning)
      #expect(rest.completedRounds == rounds)
      #expect(timer.countdown.isRunning && timer.stopwatch.isRunning)
      #expect(wellness.canContinueFocus)
    }
  }

  @Test func screenSleepPreservesDeadlineWithoutDisplayTimersAndCompletesOnce() async throws {
    try await fixture(timers: true) { settings, _, wellness, clock in
      settings.timerPreferences.sleepDisplayDuringBreak = true
      var sleeps = 0
      var completions = 0
      wellness.onSleepDisplay = { sleeps += 1 }
      wellness.onBreakCompleted = { completions += 1 }
      wellness.startBreak(.short)
      let duration = wellness.eyeRestDuration
      wellness.startBreak(.long)
      #expect(sleeps == 1 && wellness.breakKind == .short)
      clock.seconds = 10
      wellness.suspend(preservingRest: true)
      wellness.suspend(preservingRest: true)
      #expect(wellness.isEyeRestActive && !wellness.hasDisplayTimer && wellness.hasDeadlineTimer)
      clock.seconds = 20
      wellness.resume()
      #expect(wellness.isEyeRestActive && wellness.eyeRestSecondsRemaining == duration - 20)
      wellness.suspend(preservingRest: true)
      clock.seconds = duration + 100
      wellness.resume()
      wellness.refresh()
      await wellness.flush()
      #expect(completions == 1 && sleeps == 1 && !wellness.isEyeRestActive)
      #expect(wellness.summary.today?.restSeconds == duration)
    }
  }

  @Test func screenChangesDuringSuspendedBreakDoNotRecreateOverlays() async throws {
    try await fixture { _, rest, wellness, clock in
      _ = NSApplication.shared
      let windows = RestWindowController(rest: rest, wellness: wellness)
      defer { windows.hideRest() }
      wellness.startBreak(.short)
      let duration = wellness.eyeRestDuration
      wellness.suspend(preservingRest: true)
      #expect(wellness.isEyeRestActive && wellness.isSystemPaused)
      NotificationCenter.default.post(
        name: NSApplication.didChangeScreenParametersNotification, object: nil)
      #expect(windows.restOverlayCount == 0)
      windows.ensureRestVisible()
      #expect(windows.restOverlayCount == 0)
      clock.seconds = duration + 1
      wellness.refresh()
      #expect(!wellness.isEyeRestActive)
      NotificationCenter.default.post(
        name: NSApplication.didChangeScreenParametersNotification, object: nil)
      wellness.resume()
      #expect(windows.restOverlayCount == 0)
    }
  }

  @Test func suspendedBreakCanShowOverlaysAgainBeforeDeadline() async throws {
    try await fixture { _, rest, wellness, _ in
      _ = NSApplication.shared
      let windows = RestWindowController(rest: rest, wellness: wellness)
      defer { windows.hideRest() }
      wellness.startBreak(.short)
      windows.showRest()
      #expect(windows.restOverlayCount == NSScreen.screens.count)
      wellness.suspend(preservingRest: true)
      windows.showRest()
      #expect(windows.restOverlayCount == 0)
      wellness.resume()
      windows.ensureRestVisible()
      #expect(windows.restOverlayCount == NSScreen.screens.count)
    }
  }

  @Test func disableWhileScreenSleepsEndsManualBreakWithoutCompletion() async throws {
    try await fixture { settings, _, wellness, clock in
      var completions = 0
      wellness.onBreakCompleted = { completions += 1 }
      wellness.startBreak(.long)
      clock.seconds = 10
      wellness.suspend(preservingRest: true)
      settings.restEnabled = false
      wellness.sync()
      #expect(!wellness.isEyeRestActive && completions == 0)
      wellness.resume()
      #expect(!wellness.isEyeRestActive)
    }
  }

  @Test func embeddedEyeBreakCountsScreenOffSegmentOnce() async throws {
    try await fixture { _, rest, wellness, clock in
      rest.setRunning(true)
      clock.seconds = 1500
      rest.sync()
      clock.seconds = 1510
      wellness.startShortRest()
      clock.seconds = 1520
      wellness.suspend(preservingRest: true)
      rest.suspend()
      clock.seconds = 1570
      wellness.refresh()
      await wellness.flush()
      #expect(wellness.isEyeRestActive == false && wellness.isSystemPaused)
      #expect(wellness.summary.today?.restSeconds == 70)
      #expect(rest.isRunning == false)
      wellness.resume()
      wellness.refresh()
      await wellness.flush()
      #expect(wellness.summary.today?.restSeconds == 70)
    }
  }

}
