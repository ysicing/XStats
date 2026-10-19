// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Testing
@testable import XStatsUI

struct TimerSessionTests {
  @Test func countdownUsesDeadlineAndFinishesOnlyOnce() {
    var timer = CountdownSession(duration: 90)
    timer.start(at: 10)
    #expect(timer.remaining(at: 40) == 60)
    timer.pause(at: 40)
    #expect(timer.remaining(at: 100) == 60)
    timer.start(at: 100)
    let completed = timer.advance(to: 1000)
    #expect(completed)
    #expect(timer.remaining(at: 1000) == 0)
    let repeated = timer.advance(to: 1001)
    #expect(repeated == false)
    timer.start(at: 1001)
    #expect(timer.remaining(at: 1001) == 90)
  }

  @Test func stopwatchPreservesElapsedTimeAndBoundsLaps() {
    var watch = StopwatchSession()
    watch.start(at: 10)
    watch.lap(at: 12)
    watch.pause(at: 15)
    #expect(watch.elapsed(at: 100) == 5)
    watch.start(at: 100)
    watch.lap(at: 103)
    #expect(watch.laps.map(\.duration) == [2, 6])
    #expect(watch.elapsed(at: 3600) == 3505)
    for index in 1...300 { watch.lap(at: 3600 + Double(index)) }
    #expect(watch.laps.count == StopwatchSession.maximumLaps)
    watch.reset()
    #expect(watch.elapsed(at: 4000) == 0)
    #expect(watch.laps.isEmpty)
    #expect(watch.isRunning == false)
  }

  @Test func formattingPreservesHoursAndUsesExplicitLocale() {
    let english = Locale(identifier: "en_US")
    #expect(TimerFormat.clock(3600.2, locale: english) == "1:00:01")
    #expect(TimerFormat.clock(59.9, countingDown: false, locale: english) == "00:59")
    #expect(TimerFormat.lap(61.25, locale: english) == "01:01.25")
    #expect(TimerFormat.clock(.infinity, locale: english) == "00:00")
  }

  @Test func invalidPreferencesAreBoundedWithoutChangingLegacyDefaults() {
    var preferences = TimerPreferences()
    preferences.countdownSeconds = -10
    preferences.longBreakInterval = 100
    preferences.targetRounds = -1
    #expect(preferences.normalized.countdownSeconds == 1)
    #expect(preferences.normalized.longBreakInterval == 12)
    #expect(preferences.normalized.targetRounds == 0)
  }

  @Test func pomodoroHonorsIntervalAndStopsAfterTargetBreak() {
    var session = RestSession(now: 0, workMinutes: 1, restMinutes: 1, longBreakMinutes: 2)
    session.resume(at: 0)
    _ = session.advance(to: 60_000_000_000, cycle: true, longBreakInterval: 2, targetRounds: 2)
    #expect(session.phase == .rest)
    _ = session.advance(to: 180_000_000_000, cycle: true, longBreakInterval: 2, targetRounds: 2)
    #expect(session.phase == .longRest)
    _ = session.advance(to: 900_000_000_000, cycle: true, longBreakInterval: 2, targetRounds: 2)
    #expect(session.completedFocus == 2)
    #expect(session.phase == .work)
    #expect(session.isRunning == false)
  }
}

@MainActor struct TimerControllerTests {
  private final class Clock { var now: TimeInterval = 0 }

  private func fixture(_ body: (AppSettings, RestController, TimerController, Clock) throws -> Void)
    throws
  {
    let suite = "TimerTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.restEnabled = true
    let clock = Clock()
    // 日期与模拟单调时钟一起推进，避免午夜运行时把刚完成的一轮归到昨天。
    let noon = try #require(
      Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12)))
    let rest = RestController(
      settings: settings, localDefaults: defaults, sharedDefaults: nil,
      clock: { UInt64(clock.now * 1e9) }, date: { noon.addingTimeInterval(clock.now) })
    let timer = TimerController(rest: rest, settings: settings, clock: { clock.now })
    rest.sync()
    defer {
      timer.stop()
      rest.stop()
    }
    try body(settings, rest, timer, clock)
  }

  @Test func switchingViewsPreservesTimersAndConflictsRequireConfirmation() throws {
    try fixture { _, rest, timer, clock in
      timer.startPauseCountdown()
      clock.now = 10
      timer.select(.stopwatch)
      timer.startPauseStopwatch()
      timer.select(.pomodoro)
      #expect(timer.countdown.isRunning)
      rest.startPause()
      #expect(timer.pendingStart == .pomodoro)
      #expect(rest.isRunning == false)
      timer.cancelSwitch()
      #expect(timer.countdown.isRunning)
      rest.startPause()
      timer.confirmSwitch()
      #expect(rest.isRunning)
      #expect(timer.countdown.isRunning == false)
      #expect(timer.stopwatch.isRunning)
      let remaining = timer.countdown.remaining(at: clock.now)
      timer.startPauseCountdown()
      #expect(timer.pendingStart == .countdown)
      timer.confirmSwitch()
      #expect(rest.isRunning == false)
      #expect(timer.countdown.remaining(at: clock.now) == remaining)
      #expect(timer.stopwatch.isRunning)
    }
  }

  @Test func invisibleAndSuspendedTimersDoNotPollAndCompletionIsOnce() throws {
    try fixture { settings, _, timer, clock in
      var completions = 0
      timer.onCountdownCompleted = { completions += 1 }
      timer.startPauseCountdown()
      timer.startPauseStopwatch()
      #expect(timer.hasDeadlineTimer)
      #expect(timer.hasDisplayTimer == false)
      timer.select(.stopwatch)
      timer.setPageVisible(true)
      #expect(timer.hasDisplayTimer)
      timer.suspend()
      // 倒计时按单调时钟走，挂起只停读数刷新，截止唤醒保留。
      #expect(timer.hasDeadlineTimer)
      #expect(timer.hasDisplayTimer == false)
      clock.now = 2000
      timer.resume()
      timer.refresh()
      #expect(completions == 1)
      #expect(timer.stopwatch.elapsed(at: clock.now) == 2000)
      settings.restEnabled = false
      timer.sync()
      #expect(timer.hasDeadlineTimer == false)
      #expect(timer.hasDisplayTimer == false)
      #expect(timer.stopwatch.isRunning == false)
    }
  }

  @Test func countdownCompletesWhileSuspendedAndResumeDoesNotRepeat() throws {
    try fixture { _, _, timer, clock in
      var completions = 0
      timer.onCountdownCompleted = { completions += 1 }
      // 暂停再继续以重排一个极短的真实截止定时器，避免等待完整时长。
      timer.startPauseCountdown()
      clock.now = timer.countdown.duration - 0.02
      timer.startPauseCountdown()
      timer.startPauseCountdown()
      timer.suspend()
      #expect(timer.hasDeadlineTimer)
      clock.now = timer.countdown.duration + 1
      // 不调用 refresh/resume，仅依靠挂起期间保留的截止定时器触发。
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
      #expect(completions == 1)
      #expect(timer.countdown.isFinished)
      timer.resume()
      timer.refresh()
      #expect(completions == 1)
    }
  }

  @Test func confirmSwitchWithUnmetPomodoroPreconditionKeepsModeAndCountdown() throws {
    try fixture { settings, rest, timer, _ in
      timer.select(.stopwatch)
      timer.startPauseCountdown()
      rest.skip()
      #expect(timer.pendingStart == .pomodoro)
      settings.restMode = .workday
      #expect(rest.isWorkdayActive == false)
      timer.confirmSwitch()
      #expect(timer.pendingStart == nil)
      #expect(timer.mode == .stopwatch)
      #expect(timer.countdown.isRunning)
      #expect(rest.isRunning == false)
    }
  }

  @Test func backgroundStopwatchDoesNotPollWhilePomodoroOwnsVisibleReadouts() throws {
    try fixture { _, rest, timer, _ in
      timer.setPageVisible(true)
      timer.setMenuVisible(true)
      timer.startPauseStopwatch()
      #expect(timer.hasDisplayTimer)
      rest.startPause()
      timer.reconcilePresentation()
      #expect(timer.hasDisplayTimer == false)
      timer.select(.stopwatch)
      #expect(timer.hasDisplayTimer)
      timer.setPageVisible(false)
      #expect(timer.hasDisplayTimer == false)
      rest.setRunning(false)
      timer.reconcilePresentation()
      #expect(timer.hasDisplayTimer)
    }
  }

  @Test func eyeRestSuppressesOnlyCoveredCompactReadouts() throws {
    try fixture { _, _, timer, _ in
      timer.select(.stopwatch)
      timer.setMenuVisible(true)
      timer.startPauseStopwatch()
      #expect(timer.hasDisplayTimer)
      timer.setCompactReadoutsCovered(true)
      #expect(timer.hasDisplayTimer == false)
      #expect(timer.stopwatch.isRunning)
      timer.setPageVisible(true)
      #expect(timer.hasDisplayTimer)
      timer.setPageVisible(false)
      #expect(timer.hasDisplayTimer == false)
      timer.setCompactReadoutsCovered(false)
      #expect(timer.hasDisplayTimer)
    }
  }

  @Test func inactivePomodoroCommandsDoNotInterruptCountdown() throws {
    try fixture { settings, rest, timer, _ in
      settings.restMode = .workday
      timer.startPauseCountdown()
      rest.skip()
      rest.postponeFiveMinutes()
      #expect(timer.pendingStart == nil)
      #expect(timer.countdown.isRunning)
    }
  }

  @Test func externalSkipKeepsItsActionAfterConflictConfirmation() throws {
    try fixture { settings, rest, timer, _ in
      timer.startPauseCountdown()
      rest.skip()
      #expect(timer.pendingStart == .pomodoro)
      timer.confirmSwitch()
      #expect(rest.phase == .rest)
      #expect(rest.isRunning)
      #expect(timer.countdown.isRunning == false)
      timer.startPauseCountdown()
      settings.restEnabled = false
      timer.sync()
      timer.confirmSwitch()
      #expect(timer.countdown.isRunning == false)
      #expect(timer.pendingStart == nil)
    }
  }

  @Test func reachedPomodoroTargetStartsANewSessionWithoutErasingHistory() throws {
    try fixture { settings, rest, _, clock in
      settings.timerPreferences.targetRounds = 1
      settings.restMode = .cycle
      rest.startPause()
      clock.now = 30 * 60
      rest.sync()
      #expect(rest.completedRounds == 1)
      #expect(rest.completedToday == 1)
      #expect(rest.isRunning == false)
      rest.startPause()
      #expect(rest.completedRounds == 0)
      #expect(rest.completedToday == 1)
      #expect(rest.isRunning)
    }
  }

  @Test func menuReadingRetainsPausedCountdownAcrossModeSwitches() throws {
    try fixture { _, rest, timer, clock in
      timer.select(.countdown)
      timer.startPauseCountdown()
      clock.now = 12
      timer.startPauseCountdown()
      timer.select(.stopwatch)
      let reading = TimerMenuBarReading(timer: timer, rest: rest)
      #expect(reading.mode == .countdown)
      #expect(reading.state == .paused)
      #expect(reading.seconds == 888)
      #expect(timer.presentedMode == .countdown)
      #expect(timer.hasDisplayTimer == false)
    }
  }

  @Test func menuReadingPrioritizesRunningTimersAndEyeRest() throws {
    try fixture { _, rest, timer, clock in
      timer.select(.stopwatch)
      timer.startPauseStopwatch()
      clock.now = 5
      timer.refresh()
      #expect(TimerMenuBarReading(timer: timer, rest: rest).mode == .stopwatch)
      rest.startPause()
      #expect(TimerMenuBarReading(timer: timer, rest: rest).mode == .pomodoro)
      let eye = TimerMenuBarReading(timer: timer, rest: rest, eyeRestRemaining: 42)
      #expect(eye.mode == nil)
      #expect(eye.seconds == 42)
      #expect(eye.state == .running)
      rest.endSession()
      timer.startPauseStopwatch()
      #expect(TimerMenuBarReading(timer: timer, rest: rest).state == .paused)
      timer.resetStopwatch()
      #expect(TimerMenuBarReading(timer: timer, rest: rest).seconds == nil)
      timer.select(.countdown)
      timer.startPauseCountdown()
      clock.now = 2000
      timer.refresh()
      #expect(TimerMenuBarReading(timer: timer, rest: rest).state == .finished)
      #expect(TimerMenuBarReading(timer: timer, rest: rest).seconds == 0)
    }
  }

  @Test func popoverDemandRefreshesParallelStopwatchAndClosesWithoutStoppingIt() throws {
    try fixture { _, rest, timer, _ in
      rest.startPause()
      timer.startPauseStopwatch()
      timer.setPopoverVisible(true)
      #expect(timer.hasDisplayTimer)
      timer.startPauseCountdown()
      #expect(timer.pendingStart == .countdown)
      timer.setPopoverVisible(false)
      #expect(timer.pendingStart == nil)
      #expect(timer.hasDisplayTimer == false)
      #expect(timer.stopwatch.isRunning)
      #expect(rest.isRunning)
      timer.setPopoverVisible(true)
      timer.suspend()
      #expect(timer.hasDisplayTimer == false)
    }
  }

  @Test func contextMenuRoutesToPageAndHUDWithoutStartingTimers() throws {
    try fixture { settings, _, _, _ in
      let model = AppModel(
        settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
      var openedPage: PanelTab?
      let windows = RestWindowController(
        rest: model.rest, wellness: model.wellness, timer: model.timer)
      defer {
        windows.stop()
        model.timer.stop()
        model.rest.stop()
      }
      model.openMainWindow = { openedPage = $0 }
      let controller = RestMenuBarController(
        model: model, windows: windows, prepareToShow: {})
      let menu = controller.contextMenu()
      #expect(menu.items.filter { !$0.isSeparatorItem }.count == 6)
      for item in menu.items.prefix(2) {
        let action = try #require(item.action)
        #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
      }
      #expect(openedPage == .rest)
      #expect(windows.isHUDVisible)
      #expect(model.timer.countdown.isRunning == false)
      #expect(model.timer.stopwatch.isRunning == false)
    }
  }

  @Test func legacyPreferencesAndNewBackupRoundTrip() throws {
    let suite = "TimerMigrationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(45, forKey: "restWorkMinutes")
    defaults.set("workday", forKey: "restMode")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.restWorkMinutes == 45)
    #expect(settings.restMode == .workday)
    #expect(settings.timerPreferences.mode == .pomodoro)
    #expect(settings.timerPreferences.longBreakInterval == 4)
    settings.timerPreferences.countdownSeconds = 123
    settings.timerPreferences.targetRounds = 6
    let backup = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    settings.timerPreferences = TimerPreferences()
    settings.apply(backup)
    let restored = AppSettings(defaults: defaults)
    #expect(restored.timerPreferences.countdownSeconds == 123)
    #expect(restored.timerPreferences.targetRounds == 6)
  }
}

/// 刻度可能越界、收到非有限辅助输入、改变不支持的番茄配置或在禁用时回写。
@MainActor struct TimerRulerTests {
  @Test func selectionClampsBoundsAndRejectsInvalidInput() {
    let control = TimerRulerControl()
    var emitted: [Int] = []
    control.onSelect = { emitted.append($0) }
    control.selectIndex(-100)
    #expect(control.selectedMinutes == 1)
    control.selectIndex(9999)
    #expect(control.selectedMinutes == 1439)
    control.selectIndex(.nan)
    control.setAccessibilityValue(NSNumber(value: Double.infinity))
    #expect(emitted == [1, 1439])
    control.isEnabled = false
    control.selectIndex(20)
    #expect(control.accessibilityPerformDecrement() == false)
    #expect(emitted == [1, 1439])
  }

  @Test func selectingRoundedMinuteCommitsPartialDurationOnce() {
    let control = TimerRulerControl()
    control.selectedMinutes = 15
    control.hasPartialMinute = true
    var values: [Int] = []
    control.onSelect = { values.append($0) }
    control.selectIndex(14)
    control.selectIndex(14)
    #expect(values == [15])
    #expect(control.hasPartialMinute == false)
  }

  @Test func pomodoroUsesOnlyPersistableOptions() {
    let control = TimerRulerControl()
    control.options = AppSettings.restWorkOptions
    control.selectedMinutes = 25
    #expect(control.accessibilityPerformIncrement())
    #expect(control.selectedMinutes == 30)
    control.setAccessibilityValue(NSNumber(value: 44))
    #expect(control.selectedMinutes == 45)
    #expect(control.accessibilityPerformDecrement())
    #expect(control.selectedMinutes == 30)
    #expect(control.accessibilityValue() as? NSNumber == 30)
  }

  @Test func dragAndClickChooseValuesWithoutRepeatedCallbacks() throws {
    let control = TimerRulerControl(frame: NSRect(x: 0, y: 0, width: 240, height: 64))
    control.selectedMinutes = 15
    var values: [Int] = []
    control.onSelect = { values.append($0) }
    let down = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 120, y: 30), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let drag = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDragged, location: NSPoint(x: 96, y: 30), modifierFlags: [], timestamp: 1,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    control.mouseDown(with: down)
    control.mouseDragged(with: drag)
    control.mouseDragged(with: drag)
    control.mouseUp(with: drag)
    #expect(values == [17])
    control.mouseDown(with: down)
    control.mouseUp(with: down)
    #expect(values == [17])
  }
}

@MainActor struct TimerHUDStyleTests {
  @Test func stopwatchHidesMenuWithoutOverwritingSavedStyleAndEyeRestOverridesIt() async throws {
    let name = "TimerHUDStyleTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    settings.restEnabled = true
    let rest = RestController(settings: settings, localDefaults: defaults, sharedDefaults: nil)
    let timer = TimerController(rest: rest, settings: settings, clock: { 123 })
    let wellness = WellnessController(
      rest: rest, settings: settings,
      store: WellnessActivityStore(url: nil), schedulesTimers: false)
    let view = RestHUDView(rest: rest, close: {}, wellness: wellness, timer: timer)
    for style in RestHUDStyle.allCases {
      settings.restHUDStyle = style
      for mode in TimerMode.allCases {
        timer.select(mode)
        #expect(view.showsStyleMenu == (mode != .stopwatch))
        #expect(view.displayStyle == (mode == .stopwatch ? .countdown : style))
        #expect(settings.restHUDStyle == style)
      }
    }
    settings.restHUDStyle = .ring
    timer.select(.stopwatch)
    timer.startPauseStopwatch()
    #expect(view.showsStyleMenu == false)
    wellness.startShortRest()
    #expect(view.showsStyleMenu)
    #expect(view.displayStyle == .ring)
    wellness.finishEyeRest(completed: false)
    #expect(view.showsStyleMenu == false)
    #expect(view.displayStyle == .countdown)
    #expect(settings.restHUDStyle == .ring)
    #expect(AppSettings(defaults: defaults).restHUDStyle == .ring)
    timer.stop()
    rest.stop()
    await wellness.prepareForTermination()
  }
}

@MainActor struct TimerEntryTests {
  @Test func legacyPreferencesKeepAllSavedFieldsAndDefaultToNoDisplaySleep() throws {
    let data = Data(
      #"{"mode":"countdown","countdownSeconds":1234,"longBreakInterval":7,"targetRounds":8}"#.utf8)
    let decoded = try JSONDecoder().decode(TimerPreferences.self, from: data)
    #expect(decoded.mode == .countdown && decoded.countdownSeconds == 1234)
    #expect(decoded.longBreakInterval == 7 && decoded.targetRounds == 8)
    #expect(!decoded.sleepDisplayDuringBreak)
    var updated = decoded
    updated.sleepDisplayDuringBreak = true
    let restored = try JSONDecoder().decode(
      TimerPreferences.self, from: JSONEncoder().encode(updated))
    #expect(restored == updated)
  }
  @Test func duplicateShortcutsDoNotChooseAnArbitraryAction() {
    let key = HotKey(keyCode: 1, modifiers: [.command, .option], key: "s")
    let other = HotKey(keyCode: 2, modifiers: [.command, .option], key: "d")
    #expect(
      HotKeyCenter.duplicateActions(in: [
        .openTimer: key, .startLongBreak: key, .sleepDisplay: other,
      ]) == [.openTimer, .startLongBreak])
    #expect(HotKeyAction.startEyeRest.carbonID == 6)
    #expect(HotKeyAction.openTimer.requiresTimer && !HotKeyAction.sleepDisplay.requiresTimer)
  }
}

@MainActor struct TimerShortcutTests {
  @Test func switchingRecorderStopsOnlyPreviousOwner() {
    let session = ShortcutRecordingSession()
    let first = UUID()
    let second = UUID()
    var firstStopped = 0
    var secondStopped = 0
    session.begin(first) {
      firstStopped += 1
      session.end(first)
    }
    session.begin(second) {
      secondStopped += 1
      session.end(second)
    }
    #expect(firstStopped == 1 && secondStopped == 0)
    session.end(first)
    session.cancel()
    #expect(firstStopped == 1 && secondStopped == 1)
    session.cancel()
    #expect(secondStopped == 1)
  }
  @Test func recordingMutualExclusionIsSymmetric() {
    let session = ShortcutRecordingSession()
    let xstats = UUID()
    let capture = UUID()
    var xstatsRecording = false
    var captureRecording = false
    func startXStats() {
      session.begin(xstats) {
        xstatsRecording = false
        session.end(xstats)
      }
      xstatsRecording = true
    }
    func startCapture() {
      session.begin(capture) {
        captureRecording = false
        session.end(capture)
      }
      captureRecording = true
    }
    startCapture()
    startXStats()
    #expect(xstatsRecording && !captureRecording)
    startCapture()
    #expect(captureRecording && !xstatsRecording)
    session.end(capture)
    session.cancel()
    #expect(captureRecording)
  }
  @Test(arguments: TimerMode.allCases) func localKeysOnlyControlSelectedMode(_ mode: TimerMode) {
    #expect(TimerKeyboardShortcuts.command(keyCode: 49, modifiers: [], mode: mode) == .primary)
    #expect(TimerKeyboardShortcuts.command(keyCode: 49, modifiers: .command, mode: mode) == nil)
    #expect(
      TimerKeyboardShortcuts.command(keyCode: 37, modifiers: .command, mode: mode)
        == (mode == .stopwatch ? .lap : nil))
    #expect(
      TimerKeyboardShortcuts.command(keyCode: 37, modifiers: [.command, .shift], mode: mode) == nil)
    #expect(TimerKeyboardShortcuts.command(keyCode: 53, modifiers: [], mode: mode) == nil)
  }
}
