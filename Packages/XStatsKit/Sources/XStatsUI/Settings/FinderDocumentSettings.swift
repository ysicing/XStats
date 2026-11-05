// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct FinderDocumentSettings: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot

  var body: some View {
    let controller = model.finderDocuments
    VStack(alignment: .leading, spacing: DS.Space.s2) {
      SettingRow(
        title: tr("Finder 新建文档"),
        subtitle: tr("在任意文件夹中右键新建演示文稿、表格、文字文档、TXT 和 Markdown。"),
        icon: "doc.badge.plus"
      ) {
        DSToggle(
          isOn: Binding(
            get: { model.settings.finderDocumentsEnabled },
            set: { controller.setEnabled($0) }),
          label: tr("Finder 新建文档"))
      }
      if model.settings.finderDocumentsEnabled && !controller.extensionEnabled {
        Button(tr("在系统设置中启用 Finder 扩展…")) { controller.openExtensionSettings() }
          .buttonStyle(.link)
      }
      if let error = controller.error {
        Text(verbatim: error).dsFont(.xs).foregroundStyle(DS.Palette.error)
      }
    }
    .onAppear { if !isSnapshot { controller.refreshStatus() } }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      if !isSnapshot { controller.refreshStatus() }
    }
  }
}
