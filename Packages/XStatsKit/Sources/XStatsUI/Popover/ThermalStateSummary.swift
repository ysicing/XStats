// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

/// 温度详情与能耗页共用 macOS 热压力提示，与传感器温度读数独立。
struct ThermalStateSummary: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let state = model.store.thermalState
    StatusBadge(
      text: state?.pressureLabel ?? tr("热压力：未知"),
      tone: state.map(Tone.forThermalState) ?? .neutral
    )
    .help(tr("由 macOS 报告的系统热状态，与 CPU 温度读数独立。"))
  }
}
