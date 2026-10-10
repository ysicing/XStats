// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

/// 统一专注流程：页面只呈现当前阶段，自动衔接在设置中管理。
struct RestPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let rest = model.rest
        let isBreak = rest.phase.isResting
        let accent: Color = isBreak ? .green : .orange

        PageScroll {
            Card {
                HStack {
                    Label(tr("专注"), systemImage: "timer").dsFont(.sm, weight: .semibold)
                    Spacer()
                    RestOptionsButton()
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
                            Text(WellnessFormat.timer(rest.secondsRemaining))
                                .font(.system(size: 48, weight: .light, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(DS.Palette.textPrimary)
                            Text(rest.isRunning ? tr("计时中") : rest.primaryAction == .resume ? tr("已暂停") : tr("待开始"))
                                .dsFont(.xs)
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .frame(width: 214, height: 214)

                    HStack(spacing: DS.Space.s2) {
                        Button { rest.startPause() } label: {
                            // 以所有操作文案的自然宽度预留空间，开始/暂停切换时按钮位置不变。
                            ZStack {
                                ForEach(RestPrimaryAction.allCases, id: \.self) { action in
                                    Text(action.title).hidden().accessibilityHidden(true)
                                }
                                Text(rest.primaryAction.title)
                            }
                        }
                        .buttonStyle(DSButtonStyle(kind: .primary))
                        Button(tr("结束")) { rest.endSession() }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                            .disabled(!rest.canEndSession)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.s4)
            }

            WellnessHealthCard()
            WellnessTodayCard()
        }
        .onAppear {
            guard !isSnapshot else { return }
            rest.sync()
            rest.setPageVisible(true)
            model.wellness.sync()
            model.wellness.setPageVisible(true)
        }
        .onDisappear {
            if !isSnapshot {
                rest.setPageVisible(false)
                model.wellness.setPageVisible(false)
            }
        }
    }
}

extension RestPhase {
    var title: String {
        switch self {
        case .work: tr("专注")
        case .rest: tr("休息")
        case .longRest: tr("长休息")
        }
    }
}
