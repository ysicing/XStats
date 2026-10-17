// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct CountdownCard: View {
  let timer: TimerController
  private var editable: Bool { !timer.countdown.isRunning && !timer.countdown.canContinue }

  var body: some View {
    Card {
      HStack {
        Label(tr("倒计时"), systemImage: "timer").dsFont(.sm, weight: .semibold)
        Spacer()
      }
      VStack(spacing: DS.Space.s4) {
        Text(TimerFormat.clock(timer.remaining))
          .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
          .foregroundStyle(DS.Palette.textPrimary)
          .lineLimit(1).minimumScaleFactor(0.6)
        Text(
          tr(
            timer.countdown.isFinished
              ? "倒计时结束"
              : timer.countdown.isRunning ? "计时中" : timer.countdown.canContinue ? "已暂停" : "待开始")
        )
        .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
        HStack(spacing: DS.Space.s3) {
          durationField("小时", divisor: 3600, maximum: 23)
          durationField("分钟", divisor: 60, maximum: 59)
          durationField("秒", divisor: 1, maximum: 59)
        }
        .disabled(!editable)
        HStack(spacing: DS.Space.s2) {
          ForEach([5, 15, 30, 60], id: \.self) { minutes in
            Button(tr("\(WellnessFormat.number(minutes)) 分钟")) {
              timer.settings.timerPreferences.countdownSeconds = minutes * 60
              timer.resetCountdown()
            }.buttonStyle(DSButtonStyle(kind: .secondary))
          }
        }.disabled(!editable)
        HStack(spacing: DS.Space.s2) {
          Button(tr(timer.countdown.isRunning ? "暂停" : timer.countdown.canContinue ? "继续" : "开始")) {
            timer.startPauseCountdown()
          }.buttonStyle(DSButtonStyle(kind: .primary))
          Button(tr("重置")) { timer.resetCountdown() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
        }
      }
      .frame(maxWidth: .infinity).padding(.vertical, DS.Space.s4)
    }
  }

  private func durationField(_ label: String, divisor: Int, maximum: Int) -> some View {
    VStack(spacing: DS.Space.s1) {
      Text(tr(label)).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      TextField(
        tr(label),
        value: Binding(
          get: {
            timer.settings.timerPreferences.normalized.countdownSeconds / divisor % (maximum + 1)
          },
          set: { value in
            let current = timer.settings.timerPreferences.normalized.countdownSeconds
            let old = current / divisor % (maximum + 1)
            let updated = max(1, current + (min(maximum, max(0, value)) - old) * divisor)
            // 失焦可能重复提交相同值；不能因此重置刚由按钮启动的倒计时。
            guard updated != current else { return }
            timer.settings.timerPreferences.countdownSeconds = updated
            timer.resetCountdown()
          }), format: .number.grouping(.never)
      )
      .textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
      .frame(width: 72).accessibilityLabel(tr(label))
    }
  }
}

struct StopwatchCard: View {
  let timer: TimerController

  var body: some View {
    Card {
      HStack {
        Label(tr("秒表"), systemImage: "stopwatch").dsFont(.sm, weight: .semibold)
        Spacer()
      }
      VStack(spacing: DS.Space.s4) {
        Text(TimerFormat.clock(timer.elapsed, countingDown: false))
          .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
          .lineLimit(1).minimumScaleFactor(0.6)
        Text(tr(timer.stopwatch.isRunning ? "计时中" : timer.elapsed > 0 ? "已暂停" : "待开始"))
          .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
        HStack(spacing: DS.Space.s2) {
          Button(tr(timer.stopwatch.isRunning ? "暂停" : timer.elapsed > 0 ? "继续" : "开始")) {
            timer.startPauseStopwatch()
          }.buttonStyle(DSButtonStyle(kind: .primary))
          Button(tr("计次")) { timer.recordLap() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(
              !timer.stopwatch.isRunning
                || timer.stopwatch.laps.count >= StopwatchSession.maximumLaps)
          Button(tr("重置")) { timer.resetStopwatch() }
            .buttonStyle(DSButtonStyle(kind: .secondary)).disabled(timer.stopwatch.isRunning)
        }
      }.frame(maxWidth: .infinity).padding(.vertical, DS.Space.s4)
      if !timer.stopwatch.laps.isEmpty {
        HStack {
          Text(tr("分段"))
          Spacer()
          Text(tr("分段用时"))
          Spacer()
          Text(tr("累计用时"))
        }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        ForEach(timer.stopwatch.laps.reversed()) { lap in
          HStack {
            Text(WellnessFormat.number(lap.id))
            Spacer()
            Text(TimerFormat.lap(lap.duration))
            Spacer()
            Text(TimerFormat.lap(lap.total))
          }.dsFont(.sm).monospacedDigit().padding(.vertical, DS.Space.s1)
        }
      }
      if timer.stopwatch.laps.count == StopwatchSession.maximumLaps {
        Text(tr("已记录 200 次分段；重置后可重新记录。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
    }
  }
}
