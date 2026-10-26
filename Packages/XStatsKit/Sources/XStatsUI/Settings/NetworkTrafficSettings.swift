// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import Metrics
import SwiftUI

struct NetworkTrafficSettings: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
  @State private var interfaces: [String] = []
  @State private var refresh = 0

  var body: some View {
    @Bindable var settings = model.settings
    HStack(spacing: DS.Space.s2) {
      Picker(tr("流量统计接口"), selection: $settings.networkInterfaceName) {
        Text(tr("自动（物理接口）")).tag("")
        ForEach(interfaces, id: \.self) { name in
          Text(verbatim: name).tag(name)
        }
        if !settings.networkInterfaceName.isEmpty,
          !interfaces.contains(settings.networkInterfaceName)
        {
          Text(verbatim: tr("\(settings.networkInterfaceName)（不可用）"))
            .tag(settings.networkInterfaceName)
        }
      }
      .pickerStyle(.menu)
      .dsFont(.sm)
      .accessibilityIdentifier("network-traffic-interface")
      MiniIconButton(systemName: "arrow.clockwise", help: tr("刷新")) { refresh += 1 }
    }
    .task(id: refresh) {
      guard !isSnapshot else { return }
      let names = await Task.detached(priority: .utility) {
        NetworkSampler.availableTrafficInterfaces()
      }.value
      guard !Task.isCancelled else { return }
      interfaces = names
    }
  }
}
