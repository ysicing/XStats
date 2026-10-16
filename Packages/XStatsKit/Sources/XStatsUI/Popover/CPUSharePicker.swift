// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct CPUSharePicker: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings
    Picker(tr("CPU 占用口径"), selection: $settings.cpuSharePerCore) {
      Text(tr("整机")).tag(false)
      Text(tr("单核")).tag(true)
    }
    .pickerStyle(.segmented)
    .controlSize(.small)
    .labelsHidden()
    .fixedSize()
    .help(settings.processCPUHint)
    .accessibilityLabel(tr("CPU 占用口径"))
  }
}
