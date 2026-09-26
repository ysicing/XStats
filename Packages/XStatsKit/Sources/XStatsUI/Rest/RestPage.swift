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
                    }
                    Spacer()
                    RestOptionsButton()
                    SegmentedControl(selection: $settings.restCycleEnabled,
                                     options: [(false, tr("单次")), (true, tr("循环"))])
                        .frame(width: 150)
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
                            Text(rest.isRunning ? tr("计时中") : tr("已暂停"))
                                .dsFont(.xs)
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .frame(width: 214, height: 214)

                    HStack(spacing: DS.Space.s2) {
                        Button(rest.isRunning ? tr("暂停") : rest.canContinue ? tr("继续") : tr("开始")) { rest.startPause() }
                            .buttonStyle(DSButtonStyle(kind: .primary))
                        Button(tr("重置")) { rest.resetCurrentPhase() }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                        Button(tr("跳过")) { rest.skip() }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
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
