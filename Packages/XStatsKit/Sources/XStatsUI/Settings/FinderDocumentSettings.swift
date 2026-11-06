// SPDX-License-Identifier: AGPL-3.0-or-later

import FinderDocuments
import Localization
import SwiftUI

struct FinderDocumentSettings: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
  @State private var showsOptions = false

  var body: some View {
    let controller = model.finderDocuments
    VStack(alignment: .leading, spacing: DS.Space.s2) {
      SettingRow(
        title: tr("Finder 新建文档"),
        subtitle: tr("在 Finder 文件夹空白处右键新建演示文稿、表格、文字文档、TXT 和 Markdown。"),
        icon: "doc.badge.plus"
      ) {
        HStack(spacing: DS.Space.s2) {
          Button(tr("设置")) { showsOptions = true }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .accessibilityLabel(tr("Finder 新建文档设置"))
          DSToggle(
            isOn: Binding(
              get: { model.settings.finderDocumentsEnabled },
              set: { controller.setEnabled($0) }),
            label: tr("Finder 新建文档"))
        }
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
    .sheet(isPresented: $showsOptions) {
      FinderDocumentOptions().environment(model)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      if !isSnapshot { controller.refreshStatus() }
    }
  }
}

struct FinderDocumentOptions: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    @Bindable var settings = model.settings
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      HStack {
        Text(tr("Finder 新建文档设置")).dsFont(.sm, weight: .semibold)
        Spacer()
        Button(tr("完成")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      Divider()
      VStack(alignment: .leading, spacing: DS.Space.s2) {
        Text(tr("文件名生成方式")).dsFont(.sm, weight: .medium)
        Picker(tr("文件名生成方式"), selection: $settings.finderDocumentNamingMode) {
          Text(tr("随机字符串（8 位）")).tag(FinderDocumentNamingMode.randomString)
          Text(tr("随机 UUID")).tag(FinderDocumentNamingMode.random)
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
      VStack(alignment: .leading, spacing: DS.Space.s2) {
        Text(tr("菜单显示的格式")).dsFont(.sm, weight: .medium)
        ForEach(FinderDocumentKind.allCases, id: \.self) { kind in
          Toggle(
            isOn: Binding(
              get: { settings.finderDocumentFormats.contains(kind) },
              set: { included in
                if included {
                  settings.finderDocumentFormats.insert(kind)
                } else {
                  settings.finderDocumentFormats.remove(kind)
                }
              })
          ) {
            Text("\(tr(kind.title)) (.\(kind.rawValue))")
          }
          .toggleStyle(.checkbox)
        }
        Text(tr("Keynote、Numbers 和 Pages 格式仅在安装对应应用后显示。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(DS.Space.s4)
    .frame(width: 440, alignment: .leading)
  }

}
