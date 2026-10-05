// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Localization
import SwiftUI

/// 总览与指标弹窗共用的更新入口；只在已挂载界面的状态变化时短暂淡入，打开弹窗即时显示。
struct UpdateAvailableButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.updates.hasAvailableUpdate {
                MiniIconButton(systemName: "arrow.up.circle", help: tr("发现新版本，查看更新"),
                               tint: DS.Palette.primary) {
                    model.updates.presentAvailableUpdate()
                }
                .accessibilityIdentifier("popover-update")
                .transition(.opacity)
            }
        }
        .dsSelectionAnimation(DS.Motion.quick, value: model.updates.hasAvailableUpdate)
    }
}
