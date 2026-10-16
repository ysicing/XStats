// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct KeepAwakeMenu: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let control = model.keepAwake
    Menu {
      Button(tr("开关防休眠")) { model.requestKeepAwake(!control.isActive) }
      if let end = control.endDate {
        Text(tr("结束时间：\(end.formatted(Date.FormatStyle(locale: L10n.locale).hour().minute()))"))
      }
      Divider()
      Picker(tr("防休眠"), selection: Binding(get: { control.mode }, set: { control.setMode($0) })) {
        ForEach(KeepAwakeController.Mode.allCases) { mode in Text(mode.title).tag(mode) }
      }
      Menu(tr("持续时间")) {
        ForEach(KeepAwakeController.Duration.allCases) { duration in
          Button(duration.title) { model.requestKeepAwake(true, duration: duration) }
        }
      }
    } label: {
      Image(systemName: control.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
        .dsFont(.xs, weight: .semibold)
        .foregroundStyle(control.isActive ? DS.Palette.primary : DS.Palette.textSecondary)
        .frame(width: DS.Size.segmentHeight, height: DS.Size.segmentHeight)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(tr("防休眠"))
    .accessibilityLabel(tr("防休眠"))
  }
}

struct FanModeMenu: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if model.settings.isModuleEnabled(.thermal), model.store.supportsFans {
      Menu {
        Picker(
          tr("散热模式"),
          selection: Binding(get: { model.fans.mode }, set: { model.requestFanMode($0) })
        ) {
          ForEach(FanController.Mode.allCases) { mode in
            if mode != .custom || model.fans.mode == .custom { Text(mode.title).tag(mode) }
          }
        }
        .disabled(model.fans.isApplying)
      } label: {
        Image(systemName: "fan")
          .dsFont(.xs, weight: .semibold)
          .foregroundStyle(
            model.fans.mode == .automatic ? DS.Palette.textSecondary : DS.Palette.primary
          )
          .frame(width: DS.Size.segmentHeight, height: DS.Size.segmentHeight)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(tr("散热模式"))
      .accessibilityLabel(tr("散热模式"))
    }
  }
}
