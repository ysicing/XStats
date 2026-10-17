// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

/// 菜单栏的一次语义快照，暂停保留数值，护眼覆盖但不改变其他计时状态。
struct TimerMenuBarReading {
  enum State { case idle, running, paused, finished }
  let mode: TimerMode?
  let state: State
  let seconds: TimeInterval?
  let phaseTitle: String

  @MainActor init(
    timer: TimerController, rest: RestController, eyeRestRemaining: TimeInterval? = nil,
    breakKind: ManualBreakKind = .eye
  ) {
    if let eyeRestRemaining {
      mode = nil
      state = .running
      seconds = eyeRestRemaining
      phaseTitle = breakKind.title
      return
    }
    let mode = timer.presentedMode
    self.mode = mode
    phaseTitle = mode == .pomodoro ? rest.phase.title : mode.title
    switch mode {
    case .countdown:
      state =
        timer.countdown.isRunning
        ? .running
        : timer.countdown.canContinue ? .paused : timer.countdown.isFinished ? .finished : .idle
      seconds = state == .idle ? nil : timer.remaining
    case .pomodoro:
      state = rest.isRunning ? .running : rest.primaryAction == .resume ? .paused : .idle
      seconds = state == .idle ? nil : rest.secondsRemaining
    case .stopwatch:
      state = timer.stopwatch.isRunning ? .running : timer.elapsed > 0 ? .paused : .idle
      seconds = state == .idle ? nil : timer.elapsed
    }
  }

  var symbol: String {
    switch mode {
    case .countdown: "timer"
    case .pomodoro: "hourglass"
    case .stopwatch: "stopwatch"
    case nil: "eye"
    }
  }

  var stateTitle: String {
    switch state {
    case .idle: tr("待开始")
    case .running: tr("计时中")
    case .paused: tr("已暂停")
    case .finished: tr("倒计时结束")
    }
  }

  var title: String {
    guard let seconds else { return "" }
    return (state == .paused ? "⏸ " : "")
      + TimerFormat.clock(seconds, countingDown: mode != .stopwatch)
  }
}
