// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

/// 可选的番茄钟主页面：计时、阶段与今日目标在同一处操作。
struct RestPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let rest = model.rest
        let isBreak = rest.phase.isResting
        let accent: Color = isBreak ? .green : .orange

        PageScroll {
            Card {
                HStack(spacing: DS.Space.s2) {
                    ForEach(RestPhase.allCases) { phase in
                        Button(phase.title) { rest.selectPhase(phase) }
                            .buttonStyle(DSButtonStyle(kind: rest.phase == phase ? .primary : .secondary))
                            .disabled(settings.restMode == .workday && !rest.isWorkdayActive)
                    }
                    Spacer()
                    RestOptionsButton()
                    SegmentedControl(selection: $settings.restMode,
                                     options: RestRunMode.allCases.map { ($0, $0.title) })
                        .frame(width: 240)
                }

                if settings.restMode == .workday {
                    Text(tr("手动开始工作，专注与休息自动交替；每 4 轮进入长休。"))
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textSecondary)
                }

                VStack(spacing: DS.Space.s4) {
                    ZStack {
                        Circle().stroke(accent.opacity(0.15), lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: rest.phaseDuration > 0
                                  ? min(1, max(0, 1 - rest.secondsRemaining / rest.phaseDuration)) : 0)
                            .stroke(accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 4) {
                            Text(rest.phase.title)
                                .dsFont(.sm, weight: .medium)
                                .foregroundStyle(DS.Palette.textSecondary)
                            Text(Self.clock(rest.secondsRemaining))
                                .font(.system(size: 48, weight: .light, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(DS.Palette.textPrimary)
                            Text(rest.isRunning ? tr("计时中")
                                 : settings.restMode == .workday && !rest.isWorkdayActive ? tr("待开始") : tr("已暂停"))
                                .dsFont(.xs)
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .frame(width: 214, height: 214)

                    HStack(spacing: DS.Space.s2) {
                        Button(primaryTitle(rest: rest, mode: settings.restMode)) { rest.startPause() }
                            .buttonStyle(DSButtonStyle(kind: .primary))
                        Button(tr("重置")) { rest.resetCurrentPhase() }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                            .disabled(settings.restMode == .workday && !rest.isWorkdayActive)
                        Button(tr("跳过")) { rest.skip() }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                            .disabled(settings.restMode == .workday && !rest.isWorkdayActive)
                        if settings.restMode == .workday && rest.isWorkdayActive {
                            Button(tr("结束工作")) { rest.endWorkday() }
                                .buttonStyle(DSButtonStyle(kind: .secondary))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.s4)
            }

            Card {
                HStack {
                    Label(tr("今日目标"), systemImage: "checkmark.circle")
                        .dsFont(.sm, weight: .semibold)
                    Spacer()
                    Text("\(rest.completedToday) / \(settings.restDailyGoal)")
                        .monospacedDigit()
                        .dsFont(.sm)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                ProgressView(value: Double(min(rest.completedToday, settings.restDailyGoal)),
                             total: Double(settings.restDailyGoal))
                    .tint(.green)
            }
        }
        .onAppear {
            rest.sync()
            rest.setPageVisible(true)
        }
        .onDisappear { rest.setPageVisible(false) }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    private func primaryTitle(rest: RestController, mode: RestRunMode) -> String {
        if rest.isRunning { return tr("暂停") }
        if mode == .workday { return rest.isWorkdayActive ? tr("继续") : tr("开始工作") }
        return rest.canContinue ? tr("继续") : tr("开始")
    }
}

extension RestPhase {
    var title: String {
        switch self {
        case .work: tr("专注")
        case .rest: tr("短休")
        case .longRest: tr("长休")
        }
    }
}
