// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

/// 菜单栏采用横向刻度与读数布局；复用原有控制器，切换标签不改变运行状态。
struct TimerPopover: View {
  @Environment(AppModel.self) private var model
  @State private var editsDuration = false
  @State private var showsRestSettings = false
  @State private var settingsShortcutBlocker = UUID()
  // 休息是弹窗内的操作页，不写入三种计时模式的持久化配置。
  @State var showsRest = false
  @State var breakKind: ManualBreakKind = .short
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
        if showsRest {
          breakContent
        } else {
          timerContent
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
    .onChange(of: showsRestSettings) { _, presented in
      if presented {
        model.timerShortcutBlockers.insert(settingsShortcutBlocker)
      } else {
        model.timerShortcutBlockers.remove(settingsShortcutBlocker)
      }
    }
    .onDisappear { model.timerShortcutBlockers.remove(settingsShortcutBlocker) }
    .tint(.orange)
    .background(
      TimerKeyboardShortcuts(
        model: model, enabled: !editsDuration,
        primaryAction: showsRest ? { performPrimaryAction() } : nil, allowsLaps: !showsRest))
  }

  @ViewBuilder private var timerContent: some View {
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
  }

  private var modeTabs: some View {
    HStack(spacing: 14) {
      ForEach(TimerMode.allCases) { mode in
        Button {
          showsRest = false
          timer.select(mode)
        } label: {
          Text(mode.title).font(
            .system(size: 12, weight: !showsRest && timer.mode == mode ? .semibold : .regular)
          )
          .foregroundStyle(
            !showsRest && timer.mode == mode ? DS.Palette.textPrimary : DS.Palette.textSecondary
          )
          .padding(.vertical, 7)
          .overlay(alignment: .bottom) {
            if !showsRest && timer.mode == mode { Capsule().fill(.orange).frame(height: 2) }
          }
        }.buttonStyle(.plain).accessibilityAddTraits(
          !showsRest && timer.mode == mode ? .isSelected : []
        )
        .accessibilityIdentifier("timer-tab-\(mode.rawValue)")
      }
      Button {
        editsDuration = false
        showsRest = true
      } label: {
        Text(tr("休息")).font(.system(size: 12, weight: showsRest ? .semibold : .regular))
          .foregroundStyle(showsRest ? DS.Palette.textPrimary : DS.Palette.textSecondary)
          .padding(.vertical, 7)
          .overlay(alignment: .bottom) {
            if showsRest { Capsule().fill(.orange).frame(height: 2) }
          }
      }.buttonStyle(.plain).accessibilityAddTraits(showsRest ? .isSelected : [])
        .accessibilityIdentifier("timer-tab-rest")
    }.accessibilityElement(children: .contain).accessibilityLabel(tr("计时模式"))
  }

  private var primaryButton: some View {
    Button(action: performPrimaryAction) {
      Text(primaryTitle).font(.system(size: 12, weight: .semibold)).fixedSize()
        .padding(.horizontal, 13).padding(.vertical, 7)
        .foregroundStyle(.orange).background(.orange.opacity(0.14), in: Capsule())
    }.buttonStyle(.plain)
      .disabled(showsRest && (timer.pendingStart != nil || model.wellness.isSystemPaused))
      .accessibilityIdentifier("timer-primary")
  }

  private func performPrimaryAction() {
    editsDuration = false
    guard showsRest else {
      timer.performPrimaryAction()
      return
    }
    guard timer.pendingStart == nil, !model.wellness.isSystemPaused else { return }
    if model.wellness.isEyeRestActive {
      model.wellness.finishEyeRest(completed: false)
    } else {
      close()
      model.wellness.startBreak(breakKind)
    }
  }

  private var primaryTitle: String {
    if showsRest { return tr(model.wellness.isEyeRestActive ? "结束休息" : "开始") }
    return switch timer.mode {
    case .countdown:
      tr(timer.countdown.isRunning ? "暂停" : timer.countdown.canContinue ? "继续" : "开始")
    case .pomodoro: rest.primaryAction == .startFocus ? tr("开始") : rest.primaryAction.title
    case .stopwatch: tr(timer.stopwatch.isRunning ? "暂停" : timer.elapsed > 0 ? "继续" : "开始")
    }
  }

  private var moreMenu: some View {
    Menu {
      Button(tr("休息设置…")) { showsRestSettings = true }
      Divider()
      Button(tr("打开计时页面"), action: openPage)
      Button(tr("显示迷你 HUD"), action: showHUD)
    } label: {
      Image(systemName: "ellipsis").frame(width: 20, height: 26)
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .accessibilityLabel(tr("更多操作"))
    .popover(isPresented: $showsRestSettings, arrowEdge: .top) {
      RestOptionsPopover(forBreaks: true)
    }
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

  private var breakContent: some View {
    @Bindable var settings = model.settings
    let wellness = model.wellness
    return VStack(alignment: .leading, spacing: 10) {
      if wellness.isEyeRestActive {
        HStack {
          Text(wellness.breakKind.title).font(.system(size: 12, weight: .medium))
          Spacer()
          Text(TimerFormat.clock(wellness.eyeRestSecondsRemaining))
            .font(.system(size: 42, weight: .light)).monospacedDigit().foregroundStyle(.orange)
            .environment(\.layoutDirection, .leftToRight)
        }.frame(minHeight: 76)
      } else {
        Picker(tr("休息类型"), selection: $breakKind) {
          Text(tr("短休息")).tag(ManualBreakKind.short)
          Text(tr("长休息")).tag(ManualBreakKind.long)
        }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
          .accessibilityIdentifier("timer-break-kind")
        HStack(spacing: 16) {
          TimerDurationRuler(
            minutes: breakMinutes,
            options: breakKind == .long
              ? AppSettings.restLongBreakOptions : AppSettings.restBreakOptions,
            label: breakKind.title
          ).frame(height: 64)
          Text(TimerFormat.clock(breakKind.duration(settings: settings)))
            .font(.system(size: 30, weight: .light)).monospacedDigit().foregroundStyle(.orange)
            .lineLimit(1).minimumScaleFactor(0.6)
            .environment(\.layoutDirection, .leftToRight)
        }.frame(minHeight: 76)
      }
      Toggle(tr("休息时关闭显示器"), isOn: $settings.timerPreferences.sleepDisplayDuringBreak)
        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
        .help(tr("唤亮屏幕后休息继续，结束时不会主动点亮屏幕。"))
        .disabled(wellness.isEyeRestActive)
        .accessibilityIdentifier("timer-break-sleep-display")
    }
  }

  private var breakMinutes: Binding<Int> {
    Binding(
      get: {
        breakKind == .long ? model.settings.restLongBreakMinutes : model.settings.restBreakMinutes
      },
      set: { value in
        guard !model.wellness.isEyeRestActive else { return }
        if breakKind == .long {
          model.settings.restLongBreakMinutes = value
        } else {
          model.settings.restBreakMinutes = value
        }
        rest.applyDurationChange()
      })
  }

  private var eyeRestRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        Text(tr("护眼提醒"))
        Spacer(minLength: 8)
        Text(TimerReminderStatus(wellness: model.wellness).title)
          .fixedSize()
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(tr("护眼提醒"))
        Text(TimerReminderStatus(wellness: model.wellness).title)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 11)).foregroundStyle(DS.Palette.textSecondary).padding(.vertical, 3)
    .accessibilityElement(children: .combine)
  }
}

/// 提醒状态按实际休息、开关、系统暂停和到期顺序呈现，不把残留截止时间当成仍在提醒。
enum TimerReminderStatus: Equatable {
  case resting, disabled, paused, pending
  case scheduled(Date)

  @MainActor init(wellness: WellnessController) {
    if wellness.isEyeRestActive {
      self = .resting
    } else if !wellness.settings.restEnabled || !wellness.settings.wellnessPreferences.breakEnabled
    {
      self = .disabled
    } else if wellness.isSystemPaused {
      self = .paused
    } else if wellness.pending.contains(.rest) {
      self = .pending
    } else if let next = wellness.nextRestAt {
      self = .scheduled(next)
    } else {
      self = .paused
    }
  }

  var title: String {
    switch self {
    case .resting: tr("休息中")
    case .disabled: tr("未开启")
    case .paused: tr("已暂停")
    case .pending: tr("等待休息")
    case .scheduled(let date): tr("下次提醒在 \(WellnessFormat.time(date))")
    }
  }
}
