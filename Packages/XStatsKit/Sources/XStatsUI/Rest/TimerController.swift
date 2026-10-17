// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation
import OSLog

/// 倒计时与番茄钟互斥，秒表独立；仅可见时刷新读数，后台只保留倒计时的一次截止唤醒。
@MainActor @Observable final class TimerController {
  private(set) var countdown: CountdownSession
  private(set) var stopwatch = StopwatchSession()
  private(set) var now: TimeInterval
  private(set) var pendingStart: TimerMode?
  private(set) var isPopoverVisible = false
  var onStateChange: (() -> Void)?
  var onCountdownCompleted: (() -> Void)?
  var onCountdownStarted: (() -> Void)?
  var onSwitchRequested: (() -> Void)?
  private var pendingPomodoroAction: RestStartRequest = .start
  private let rest: RestController
  let settings: AppSettings
  private let clock: () -> TimeInterval
  @ObservationIgnored private var deadlineTimer: Timer?
  @ObservationIgnored private var displayTimer: Timer?
  @ObservationIgnored private var scheduledDeadline: TimeInterval?
  @ObservationIgnored private var pageVisible = false
  @ObservationIgnored private var hudVisible = false
  @ObservationIgnored private var menuVisible = false
  @ObservationIgnored private var compactReadoutsCovered = false
  @ObservationIgnored private var suspended = false
  private let logger = Logger(subsystem: "work.12306.xstats", category: "Timer")

  init(
    rest: RestController, settings: AppSettings,
    clock: @escaping () -> TimeInterval = { Double(RestClock.now()) / 1e9 }
  ) {
    self.rest = rest
    self.settings = settings
    self.clock = clock
    now = clock()
    countdown = CountdownSession(
      duration: Double(settings.timerPreferences.normalized.countdownSeconds))
    rest.allowsStart = { [weak self] action in
      guard let self else { return true }
      self.refresh()
      guard self.countdown.isRunning else { return true }
      self.pendingPomodoroAction = action
      self.pendingStart = .pomodoro
      self.onSwitchRequested?()
      return false
    }
  }

  var mode: TimerMode { settings.timerPreferences.mode }
  var remaining: TimeInterval { countdown.remaining(at: now) }
  var elapsed: TimeInterval { stopwatch.elapsed(at: now) }
  var hasDisplayTimer: Bool { displayTimer != nil }
  var hasDeadlineTimer: Bool { deadlineTimer != nil }
  var presentedMode: TimerMode {
    if countdown.isRunning { return .countdown }
    if rest.isRunning { return .pomodoro }
    if stopwatch.isRunning { return .stopwatch }
    // 运行中的计时优先；全部暂停时保留所选或仍有进度的计时，避免读数消失。
    let paused = TimerMode.allCases.filter { mode in
      switch mode {
      case .countdown: countdown.canContinue
      case .pomodoro: rest.primaryAction == .resume
      case .stopwatch: elapsed > 0
      }
    }
    return paused.contains(mode) ? mode : paused.first ?? mode
  }

  func reconcilePresentation() { updateTimers() }

  func setCompactReadoutsCovered(_ covered: Bool) {
    compactReadoutsCovered = covered
    refresh()
  }

  func select(_ mode: TimerMode) {
    settings.timerPreferences.mode = mode
    refresh()
  }

  func sync() {
    guard settings.restEnabled else {
      stop()
      return
    }
    if !countdown.isRunning && !countdown.canContinue && !countdown.isFinished {
      countdown = CountdownSession(
        duration: Double(settings.timerPreferences.normalized.countdownSeconds))
    }
    refresh()
  }

  func setPopoverVisible(_ visible: Bool) {
    isPopoverVisible = visible
    if !visible { cancelSwitch() }
    refresh()
  }

  func setPageVisible(_ visible: Bool) {
    pageVisible = visible
    refresh()
  }
  func setHUDVisible(_ visible: Bool) {
    hudVisible = visible
    refresh()
  }
  func setMenuVisible(_ visible: Bool) {
    menuVisible = visible
    refresh()
  }

  func performPrimaryAction() {
    guard pendingStart == nil else { return }
    switch mode {
    case .countdown: startPauseCountdown()
    case .pomodoro: rest.startPause()
    case .stopwatch: startPauseStopwatch()
    }
  }

  func startPauseCountdown() {
    guard settings.restEnabled else { return }
    refresh()
    if countdown.isRunning {
      countdown.pause(at: now)
    } else {
      rest.sync()
      if rest.isRunning {
        pendingStart = .countdown
        onSwitchRequested?()
        return
      }
      countdown.start(at: now)
      onCountdownStarted?()
    }
    refresh()
  }

  func resetCountdown() {
    countdown = CountdownSession(
      duration: Double(settings.timerPreferences.normalized.countdownSeconds))
    refresh()
  }

  func startPauseStopwatch() {
    guard settings.restEnabled else { return }
    now = clock()
    if stopwatch.isRunning { stopwatch.pause(at: now) } else { stopwatch.start(at: now) }
    refresh()
  }

  func recordLap() {
    stopwatch.lap(at: clock())
    refresh()
  }
  func resetStopwatch() {
    stopwatch.reset()
    refresh()
  }
  func cancelSwitch() { pendingStart = nil }

  /// 先暂停另一种计时再开始，保留被暂停的进度；取消不会改变任何计时。
  func confirmSwitch() {
    guard settings.restEnabled, let pendingStart else {
      cancelSwitch()
      return
    }
    self.pendingStart = nil
    refresh()
    select(pendingStart)
    if pendingStart == .countdown {
      rest.setRunning(false)
      countdown.start(at: now)
      onCountdownStarted?()
    } else {
      if pendingPomodoroAction == .skip && settings.restMode == .workday && !rest.isWorkdayActive {
        return
      }
      if pendingPomodoroAction == .postpone && !rest.phase.isResting { return }
      countdown.pause(at: now)
      switch pendingPomodoroAction {
      case .start: rest.setRunning(true)
      case .skip: rest.skip()
      case .postpone: rest.postponeFiveMinutes()
      }
    }
    refresh()
  }

  func refresh() {
    now = clock()
    let completed = countdown.advance(to: now)
    updateTimers()
    if completed {
      logger.info("Countdown completed")
      onCountdownCompleted?()
    }
    onStateChange?()
  }

  func suspend() {
    suspended = true
    updateTimers()
  }
  func resume() {
    suspended = false
    sync()
  }

  func stop() {
    pendingStart = nil
    countdown = CountdownSession(
      duration: Double(settings.timerPreferences.normalized.countdownSeconds))
    stopwatch.reset()
    deadlineTimer?.invalidate()
    deadlineTimer = nil
    scheduledDeadline = nil
    displayTimer?.invalidate()
    displayTimer = nil
    now = clock()
    onStateChange?()
  }

  /// 仅供隔离截图注入演示状态，不调度计时器或发送通知。
  func showPreview(_ mode: TimerMode, paused: Bool = false) {
    stop()
    settings.timerPreferences.mode = mode
    now = 123
    if mode == .countdown {
      countdown.start(at: 0)
      if paused { countdown.pause(at: now) }
    } else if mode == .stopwatch {
      stopwatch.start(at: 0)
      stopwatch.lap(at: 32.45)
      stopwatch.lap(at: 78.23)
      if paused { stopwatch.pause(at: now) }
    }
  }

  private func updateTimers() {
    let enabled = settings.restEnabled && !suspended
    let deadline = enabled ? countdown.deadline : nil
    if scheduledDeadline != deadline {
      deadlineTimer?.invalidate()
      deadlineTimer = nil
      scheduledDeadline = deadline
      if let deadline {
        deadlineTimer = Timer.scheduledTimer(
          withTimeInterval: max(0.001, deadline - now), repeats: false
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.scheduledDeadline = nil
            self?.deadlineTimer = nil
            self?.refresh()
          }
        }
        deadlineTimer?.tolerance = 0.01
      }
    }
    let pageNeedsDisplay =
      pageVisible
      && ((mode == .countdown && countdown.isRunning)
        || (mode == .stopwatch && stopwatch.isRunning))
    let compactNeedsDisplay =
      (hudVisible || menuVisible) && !compactReadoutsCovered
      && ((presentedMode == .countdown && countdown.isRunning)
        || (presentedMode == .stopwatch && stopwatch.isRunning))
    // 弹窗可同时显示当前模式和并行秒表；独立于主页面与被护眼覆盖的菜单栏读数。
    let popoverNeedsDisplay =
      isPopoverVisible
      && ((mode == .countdown && countdown.isRunning) || stopwatch.isRunning)
    let needsDisplay = enabled && (pageNeedsDisplay || compactNeedsDisplay || popoverNeedsDisplay)
    if needsDisplay && displayTimer == nil {
      displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
      displayTimer?.tolerance = 0.1
    } else if !needsDisplay {
      displayTimer?.invalidate()
      displayTimer = nil
    }
  }
}
