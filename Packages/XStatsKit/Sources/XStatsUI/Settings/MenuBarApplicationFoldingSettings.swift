// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct MenuBarApplicationFoldingSettings: View {
  @Environment(AppModel.self) private var model
  @State private var managesApplications = false

  var body: some View {
    @Bindable var settings = model.settings
    let folding = model.menuBarApplicationFolding
    GroupRow(showsDivider: false) {
      SettingRow(
        title: tr("折叠菜单栏图标"),
        subtitle: tr("选择要隐藏的应用，点击菜单栏箭头收起或展开。同一应用的图标会一起变化。"),
        icon: "menubar.arrow.up.rectangle"
      ) {
        HStack {
          Button(tr("管理应用…")) { managesApplications = true }
            .buttonStyle(DSButtonStyle(kind: .secondary))
          DSToggle(isOn: $settings.menuBarFoldingEnabled, label: tr("折叠菜单栏图标"))
        }
      }
    }
    if let issue = folding.issue {
      InfoBanner(icon: "exclamationmark.triangle", text: issue)
        .padding(.horizontal, DS.Space.s4)
        .padding(.bottom, DS.Space.s3)
    }
    // sheet 挂在稳定行上，错误文案变化不会关闭管理窗口。
    Color.clear.frame(height: 0)
      .sheet(isPresented: $managesApplications) {
        MenuBarApplicationSelection(folding: folding)
      }
  }
}

private struct MenuBarApplicationSelection: View {
  let folding: MenuBarApplicationFolding
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      Text(tr("折叠菜单栏图标")).font(.headline)
      Text(tr("选择要隐藏的应用，点击菜单栏箭头收起或展开。同一应用的图标会一起变化。"))
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let issue = folding.issue {
        InfoBanner(icon: "exclamationmark.triangle", text: issue)
      }
      if folding.hasAccess {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: DS.Space.s3) {
            ForEach(folding.applications) { application in
              Toggle(
                isOn: Binding(
                  get: { folding.selected.contains(application.id) },
                  set: { folding.select(application.id, enabled: $0) })
              ) {
                HStack {
                  if let icon = application.icon {
                    Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                  }
                  Text(application.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
              .toggleStyle(.checkbox)
            }
          }.padding(.vertical, DS.Space.s2)
        }
        .disabled(folding.isBusy || folding.isCollapsed || folding.recoveryNeeded)
      } else {
        Text(tr("首次使用需授权访问菜单栏应用列表；仅访问选定文件，无需屏幕录制。"))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button(tr("授权菜单栏应用列表")) { folding.requestAccess() }
          .buttonStyle(.borderedProminent)
        Spacer()
      }
      Divider()
      HStack {
        if folding.hasAccess {
          Button(tr("刷新")) { folding.refresh() }
          if folding.issue != nil {
            Button(tr("授权访问")) { folding.requestAccess() }
          }
        }
        if folding.isCollapsed || folding.recoveryNeeded {
          Button(tr("展开菜单栏图标")) { folding.toggle() }
        } else if folding.hasAccess {
          Button(tr("收起菜单栏图标")) { folding.toggle() }
            .disabled(folding.availableSelection.isEmpty || !folding.isEnabled)
        }
        if folding.isBusy { ProgressView().controlSize(.small) }
        Spacer()
        Button(tr("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
      }
      .disabled(folding.isBusy)
    }
    .padding(20)
    .frame(width: 520, height: 430)
    .onAppear { folding.refresh() }
  }
}
