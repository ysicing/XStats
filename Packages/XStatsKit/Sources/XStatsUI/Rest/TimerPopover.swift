// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

/// 菜单栏采用横向刻度与读数布局；复用原有控制器，切换标签不改变运行状态。
struct TimerPopover: View {
  @Environment(AppModel.self) private var model
  @State private var editsDuration = false
  var openPage: () -> Void
  var showHUD: () -> Void
  var close: () -> Void
  private var timer: TimerController { model.timer }
  private var rest: RestController { model.rest }
  private var isSetup: Bool {
    switch timer.mode {
    case .countdown:
      !timer.countdown.isRunning && !timer.countdown.canContinue && !timer.countdown.isFinished
    case .pomodoro: !rest.canEndSession && rest.primaryAction == .startFocus
    case .stopwatch: timer.elapsed == 0 && !timer.stopwatch.isRunning
    }
  }

  var body: some View {
    PopoverFrame(width: 400) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          modeTabs.fixedSize()
          Spacer(minLength: 0)
          primaryButton
          moreMenu
        }
        VStack(spacing: 8) {
          modeTabs
          HStack {
            Spacer()
            primaryButton
            moreMenu
          }
        }
      }
    } content: {
      VStack(spacing: 10) {
        HStack(spacing: 16) {
          if isSetup && timer.mode != .stopwatch {
            TimerDurationRuler(
              minutes: durationMinutes,
              options: timer.mode == .pomodoro ? AppSettings.restWorkOptions : Array(1...1439),
              label: tr(timer.mode == .pomodoro ? "专注时长" : "倒计时"),
              hasPartialMinute: timer.mode == .countdown
                && model.settings.timerPreferences.normalized.countdownSeconds % 60 != 0
            )
            .frame(height: 64)
          } else {
            VStack(alignment: .leading, spacing: 6) {
              Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
              secondaryControls
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
          if isSetup && timer.mode == .countdown {
            Button {
              editsDuration.toggle()
            } label: {
              clock.font(.system(size: 30, weight: .light))
            }
            .buttonStyle(.plain).help(tr("自定义时长…"))
            .accessibilityLabel(tr("自定义时长…")).accessibilityValue(time)
          } else {
            clock.font(.system(size: isSetup ? 30 : 42, weight: .light))
          }
        }.frame(minHeight: 76)
        if editsDuration && timer.mode == .countdown && isSetup {
          HStack(spacing: 8) {
            durationField("小时", divisor: 3600, maximum: 23)
            durationField("分钟", divisor: 60, maximum: 59)
            durationField("秒", divisor: 1, maximum: 59)
          }
        }
        if timer.mode == .pomodoro && isSetup { pomodoroOptions }
        if timer.mode == .stopwatch, let lap = timer.stopwatch.laps.last {
          HStack {
            Text(tr("分段")) + Text(" " + WellnessFormat.number(lap.id))
            Spacer()
            Text(TimerFormat.lap(lap.duration)).monospacedDigit()
          }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if timer.pendingStart != nil {
          VStack(alignment: .leading, spacing: 8) {
            Text(tr("切换正在运行的计时？")).font(.system(size: 12, weight: .semibold))
            Text(tr("当前倒计时或番茄钟将暂停并保留进度，秒表不受影响。")).font(.system(size: 11)).foregroundStyle(
              .secondary)
            HStack {
              Button(tr("取消")) { timer.cancelSwitch() }
              Spacer()
              Button(tr("切换并开始")) { timer.confirmSwitch() }.tint(.orange)
            }
          }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        if timer.mode != .stopwatch && (timer.stopwatch.isRunning || timer.elapsed > 0) {
          HStack {
            Label(tr("秒表"), systemImage: "stopwatch")
            Text(TimerFormat.clock(timer.elapsed, countingDown: false)).monospacedDigit()
            Spacer()
            Button {
              timer.startPauseStopwatch()
            } label: {
              Image(systemName: timer.stopwatch.isRunning ? "pause.fill" : "play.fill")
            }
            .help(tr(timer.stopwatch.isRunning ? "暂停" : "继续"))
            .accessibilityLabel(tr(timer.stopwatch.isRunning ? "暂停" : "继续"))
            Button {
              timer.resetStopwatch()
            } label: {
              Image(systemName: "arrow.counterclockwise")
            }
            .disabled(timer.stopwatch.isRunning).help(tr("重置")).accessibilityLabel(tr("重置"))
          }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        Divider()
        eyeRestRow
      }.padding(.vertical, 4)
    }
    .onChange(of: timer.mode) { _, _ in editsDuration = false }
    .tint(.orange)
    .background(TimerKeyboardShortcuts(model: model, enabled: !editsDuration))
  }

  private var modeTabs: some View {
    HStack(spacing: 14) {
      ForEach(TimerMode.allCases) { mode in
        Button {
          timer.select(mode)
        } label: {
          Text(mode.title).font(
            .system(size: 12, weight: timer.mode == mode ? .semibold : .regular)
          )
          .foregroundStyle(timer.mode == mode ? DS.Palette.textPrimary : DS.Palette.textSecondary)
          .padding(.vertical, 7)
          .overlay(alignment: .bottom) {
            if timer.mode == mode { Capsule().fill(.orange).frame(height: 2) }
          }
        }.buttonStyle(.plain).accessibilityAddTraits(timer.mode == mode ? .isSelected : [])
      }
    }.accessibilityElement(children: .contain).accessibilityLabel(tr("计时模式"))
  }

  private var primaryButton: some View {
    Button {
      editsDuration = false
      switch timer.mode {
      case .countdown: timer.startPauseCountdown()
      case .pomodoro: rest.startPause()
      case .stopwatch: timer.startPauseStopwatch()
      }
    } label: {
      Text(primaryTitle).font(.system(size: 12, weight: .semibold)).fixedSize()
        .padding(.horizontal, 13).padding(.vertical, 7)
        .foregroundStyle(.orange).background(.orange.opacity(0.14), in: Capsule())
    }.buttonStyle(.plain)
  }

  private var primaryTitle: String {
    switch timer.mode {
    case .countdown:
      tr(timer.countdown.isRunning ? "暂停" : timer.countdown.canContinue ? "继续" : "开始")
    case .pomodoro: rest.primaryAction == .startFocus ? tr("开始") : rest.primaryAction.title
    case .stopwatch: tr(timer.stopwatch.isRunning ? "暂停" : timer.elapsed > 0 ? "继续" : "开始")
    }
  }

  private var moreMenu: some View {
    Menu {
      Button(tr("打开计时页面"), action: openPage)
      Button(tr("显示迷你 HUD"), action: showHUD)
    } label: {
      Image(systemName: "ellipsis").frame(width: 20, height: 26)
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .accessibilityLabel(tr("更多操作"))
  }

  private var clock: some View {
    Text(time).monospacedDigit().foregroundStyle(.orange)
      .lineLimit(1).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
      .frame(minWidth: 92, alignment: .trailing)
      .environment(\.layoutDirection, .leftToRight)
  }

  private var time: String {
    switch timer.mode {
    case .countdown: TimerFormat.clock(timer.remaining)
    case .pomodoro: TimerFormat.clock(rest.secondsRemaining)
    case .stopwatch: TimerFormat.clock(timer.elapsed, countingDown: false)
    }
  }

  private var status: String {
    switch timer.mode {
    case .countdown:
      tr(
        timer.countdown.isFinished
          ? "倒计时结束"
          : timer.countdown.isRunning ? "计时中" : timer.countdown.canContinue ? "已暂停" : "待开始")
    case .pomodoro:
      rest.phase.title + " · "
        + tr(rest.isRunning ? "计时中" : rest.primaryAction == .resume ? "已暂停" : "待开始")
    case .stopwatch: tr(timer.stopwatch.isRunning ? "计时中" : timer.elapsed > 0 ? "已暂停" : "待开始")
    }
  }

  @ViewBuilder private var secondaryControls: some View {
    HStack(spacing: 12) {
      switch timer.mode {
      case .countdown:
        Button(tr("重置")) { timer.resetCountdown() }
      case .pomodoro:
        Button {
          rest.skip()
        } label: {
          Image(systemName: "forward.end.fill")
        }
        .disabled(!rest.isRunning).help(tr("跳过当前阶段")).accessibilityLabel(tr("跳过当前阶段"))
        Button(tr("结束")) { rest.endSession() }.disabled(!rest.canEndSession)
      case .stopwatch:
        Button(tr("计次")) { timer.recordLap() }.disabled(
          !timer.stopwatch.isRunning || timer.stopwatch.laps.count >= StopwatchSession.maximumLaps)
        Button(tr("重置")) { timer.resetStopwatch() }.disabled(timer.stopwatch.isRunning)
      }
    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
  }

  private var durationMinutes: Binding<Int> {
    Binding(
      get: {
        timer.mode == .pomodoro
          ? model.settings.restWorkMinutes
          : model.settings.timerPreferences.normalized.countdownSeconds / 60
      },
      set: { value in
        guard isSetup else { return }
        if timer.mode == .pomodoro {
          model.settings.restWorkMinutes = value
          rest.applyDurationChange()
        } else {
          model.settings.timerPreferences.countdownSeconds = value * 60
          timer.resetCountdown()
        }
      })
  }

  private func durationField(_ label: String, divisor: Int, maximum: Int) -> some View {
    VStack(spacing: 3) {
      Text(tr(label)).font(.system(size: 10)).foregroundStyle(.secondary)
      TextField(
        tr(label),
        value: Binding(
          get: {
            model.settings.timerPreferences.normalized.countdownSeconds / divisor % (maximum + 1)
          },
          set: { value in
            guard isSetup else { return }
            let current = model.settings.timerPreferences.normalized.countdownSeconds
            let old = current / divisor % (maximum + 1)
            let updated = max(1, current + (min(maximum, max(0, value)) - old) * divisor)
            guard updated != current else { return }
            model.settings.timerPreferences.countdownSeconds = updated
            timer.resetCountdown()
          }), format: .number.grouping(.never)
      )
      .textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
    }
  }

  private var pomodoroOptions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 18) {
        breakOption(long: false)
        breakOption(long: true)
        roundsOption
      }.fixedSize()
      VStack(alignment: .leading, spacing: 6) {
        breakOption(long: false)
        breakOption(long: true)
        roundsOption
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func breakOption(long: Bool) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(tr(long ? "长休息" : "短休息")).foregroundStyle(.secondary)
      Menu {
        ForEach(long ? AppSettings.restLongBreakOptions : AppSettings.restBreakOptions, id: \.self)
        { minutes in
          Button(tr("\(WellnessFormat.number(minutes)) 分钟")) {
            if long {
              model.settings.restLongBreakMinutes = minutes
            } else {
              model.settings.restBreakMinutes = minutes
            }
            rest.applyDurationChange()
          }
        }
      } label: {
        Text(
          tr(
            "\(WellnessFormat.number(long ? model.settings.restLongBreakMinutes : model.settings.restBreakMinutes)) 分钟"
          )
        )
        .foregroundStyle(.orange)
      }.menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel(tr(long ? "长休息" : "短休息"))
    }.font(.system(size: 10))
  }

  private var roundsOption: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(tr("长休息间隔")).foregroundStyle(.secondary)
      Text(WellnessFormat.number(model.settings.timerPreferences.longBreakInterval))
        .foregroundStyle(.orange)
    }.font(.system(size: 10))
  }

  private var eyeRestRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "eye").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.wellness.isEyeRestActive ? model.wellness.breakKind.title : tr("休息")).font(
          .system(size: 11, weight: .medium))
        if model.wellness.isEyeRestActive {
          Text(TimerFormat.clock(model.wellness.eyeRestSecondsRemaining)).monospacedDigit()
        } else if !model.wellness.pending.isEmpty {
          Text(tr("待处理"))
        } else if let next = model.wellness.nextRestAt {
          Text(tr("下次提醒") + " · " + WellnessFormat.time(next))
        }
      }.font(.system(size: 10)).foregroundStyle(.secondary)
      Spacer(minLength: 4)
      RestActionsMenu(beforeAction: close)
    }.padding(.vertical, 3)
  }
}
