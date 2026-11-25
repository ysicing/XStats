// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct SyncPreferenceSettings: View {
  let preferences: SyncPreferences
  let sync: ActivitySyncController
  let settings: AppSettings
  @Environment(\.dismiss) private var dismiss
  @State private var failure: String?

  var body: some View {
    if let first = preferences.firstChoice {
      SyncPreferenceDifferences(preferences: preferences, sync: sync, decision: .first(first))
        .id(first.id)
    } else if let conflict = preferences.conflicts.first {
      SyncPreferenceDifferences(preferences: preferences, sync: sync, decision: .conflict(conflict))
        .id(conflict.id)
    } else {
      VStack(alignment: .leading, spacing: DS.Space.s4) {
        Text(tr("功能设置")).font(.headline)
        Form {
          LabeledContent(tr("外观"), value: settings.appearance.title)
          LabeledContent(tr("菜单栏布局"), value: settings.menuBarLayout.title)
          LabeledContent(tr("提醒声音"), value: settings.restSound.title)
          LabeledContent(tr("休息提醒"), value: settings.restEnabled ? tr("开启") : tr("关闭"))
        }
        if let failure { Text(verbatim: failure).foregroundStyle(.secondary) }
        HStack {
          if preferences.isEnabled {
            Button(tr("停止同步设置")) { setEnabled(false) }
          } else {
            Button(tr("开启设置同步")) { setEnabled(true) }
              .disabled(!sync.enabled)
          }
          Spacer()
          Button(tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
        }
      }
      .padding(DS.Space.s6)
      .frame(minWidth: 400)
    }
  }

  private func setEnabled(_ enabled: Bool) {
    do {
      try preferences.setEnabled(enabled)
      failure = nil
      if !enabled { dismiss() }
    } catch {
      failure = tr("无法更改设置同步")
    }
  }
}

private struct SyncPreferenceDifferences: View {
  enum Decision {
    case first(SyncPreferences.FirstChoice)
    case conflict(SyncPreferences.Choice)

    var title: String {
      switch self {
      case .first: tr("首次同步功能设置")
      case .conflict: tr("设置冲突")
      }
    }

    var fields: [SyncPreferences.Choice] {
      switch self {
      case .first(let choice): choice.fields
      case .conflict(let choice): [choice]
      }
    }
  }

  let preferences: SyncPreferences
  let sync: ActivitySyncController
  let decision: Decision
  @Environment(\.dismiss) private var dismiss
  @State private var selections: [SyncPreferences.Field: UUID] = [:]
  @State private var failure: String?

  var body: some View {
    let names = Dictionary(
      uniqueKeysWithValues: preferences.devices.compactMap { device in
        device.name.map { (device.id, $0) }
      })
    let fields = decision.fields
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      Text(decision.title).font(.headline)
      if !fields.isEmpty {
        Text(tr("只列出不同的设置。选中的值将同步到参与的 Mac。"))
          .foregroundStyle(.secondary)
        let options = VStack(alignment: .leading, spacing: DS.Space.s4) {
          ForEach(fields) { choice in
            let remoteValues = choice.remoteValues
            let picker = Picker(
              choice.field.settingsTitle,
              selection: Binding(
                get: { selections[choice.field] }, set: { selections[choice.field] = $0 })
            ) {
              Text(optionTitle(source: tr("本机"), field: choice.field, value: choice.localValue))
                .tag(nil as UUID?)
              ForEach(remoteValues) { remote in
                let source =
                  remoteValues.count == 1
                  ? tr("共享值")
                  : ActivityPageFormat.deviceName(
                    remote.deviceID, localID: preferences.deviceID, names: names)
                Text(optionTitle(source: source, field: choice.field, value: remote.value))
                  .tag(Optional(remote.deviceID))
              }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            VStack(alignment: .leading, spacing: DS.Space.s2) {
              Text(choice.field.settingsTitle).font(.subheadline.weight(.semibold))
              if remoteValues.count == 1 {
                ViewThatFits(in: .horizontal) {
                  picker.horizontalRadioGroupLayout().fixedSize()
                  picker
                }
              } else {
                picker
              }
            }
          }
        }
        ViewThatFits(in: .vertical) {
          options.fixedSize(horizontal: false, vertical: true)
          ScrollView { options.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .frame(maxHeight: 360, alignment: .topLeading)
      }
      if let failure { Text(verbatim: failure).foregroundStyle(.secondary) }
      HStack {
        if case .conflict = decision {
          Button(tr("停止同步设置")) { perform { try preferences.setEnabled(false) } }
        }
        Spacer()
        Button(tr("取消")) {
          switch decision {
          case .first: perform { try preferences.cancelFirst() }
          case .conflict: dismiss()
          }
        }
        .keyboardShortcut(.cancelAction)
        Button(tr("应用并同步")) { confirm() }
          .disabled(sync.syncing || !sync.enabled)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(DS.Space.s6)
    .frame(minWidth: 440, idealWidth: 520)
  }

  private func optionTitle(source: String, field: SyncPreferences.Field, value: String?) -> String {
    let title = field.settingsValueTitle(value)
    return tr("\(source)：\(title)")
  }

  private func confirm() {
    perform {
      switch decision {
      case .first(let choice):
        try preferences.acceptFirst(choice, selections: selections.mapValues { .device($0) })
      case .conflict(let choice):
        let selection = selections[choice.field].map(SyncPreferences.Selection.device) ?? .local
        try preferences.resolve(choice, using: selection)
      }
    }
  }

  private func perform(_ action: () throws -> Void) {
    do {
      try action()
      dismiss()
    } catch {
      failure = tr("无法更改设置同步")
    }
  }
}

extension SyncPreferences.Field {
  fileprivate var settingsTitle: String {
    switch self {
    case .appearance: tr("外观")
    case .menuBarLayout: tr("菜单栏布局")
    case .restSound: tr("提醒声音")
    case .restEnabled: tr("休息提醒")
    }
  }

  fileprivate func settingsValueTitle(_ value: String?) -> String {
    guard let value else { return tr("未设置") }
    let title: String? =
      switch self {
      case .appearance: AppearanceMode(rawValue: value)?.title
      case .menuBarLayout: MenuBarLayout(rawValue: value)?.title
      case .restSound: RestSound(rawValue: value)?.title
      case .restEnabled: Bool(value).map { $0 ? tr("开启") : tr("关闭") }
      }
    return title ?? tr("未设置")
  }
}
