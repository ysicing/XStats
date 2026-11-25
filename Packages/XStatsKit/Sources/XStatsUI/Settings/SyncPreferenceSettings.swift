// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct SyncPreferenceSettings: View {
  let preferences: SyncPreferences
  let sync: ActivitySyncController
  let settings: AppSettings
  @State private var editingScope: Bool

  init(preferences: SyncPreferences, sync: ActivitySyncController, settings: AppSettings) {
    self.preferences = preferences
    self.sync = sync
    self.settings = settings
    _editingScope = State(
      initialValue: preferences.firstChoice == nil && preferences.conflicts.isEmpty)
  }

  var body: some View {
    if !editingScope, let first = preferences.firstChoice {
      SyncPreferenceDifferences(
        preferences: preferences, sync: sync, decision: .first(first), editScope: editScope
      )
      .id(first.id)
    } else if !editingScope, let conflict = preferences.conflicts.first {
      SyncPreferenceDifferences(
        preferences: preferences, sync: sync, decision: .conflict(conflict), editScope: editScope
      )
      .id(conflict.id)
    } else {
      SyncPreferenceScope(preferences: preferences, sync: sync, settings: settings)
        .onAppear { editingScope = true }
    }
  }

  private func editScope() { editingScope = true }
}

private struct SyncPreferenceScope: View {
  typealias Field = SyncPreferences.Field

  let preferences: SyncPreferences
  let sync: ActivitySyncController
  let settings: AppSettings
  @Environment(\.dismiss) private var dismiss
  @State private var draft: Set<Field>
  @State private var failure: String?

  init(preferences: SyncPreferences, sync: ActivitySyncController, settings: AppSettings) {
    self.preferences = preferences
    self.sync = sync
    self.settings = settings
    _draft = State(initialValue: preferences.selectedFields)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      VStack(alignment: .leading, spacing: DS.Space.s1) {
        Text(tr("功能设置同步")).dsFont(.lg, weight: .semibold)
        Text(tr("选择这台 Mac 要同步的设置。"))
          .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
      }
      SettingsGroup {
        Text(tr("当前值"))
          .dsFont(.xs, weight: .medium)
          .foregroundStyle(DS.Palette.textSecondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(.horizontal, DS.Space.s4)
          .padding(.top, DS.Space.s3)
          .accessibilityHidden(true)
        ForEach(Field.allCases, id: \.self) { field in
          let value = currentValue(field)
          let valueLabel = tr("当前值")
          GroupRow(showsDivider: field != Field.allCases.first) {
            HStack(spacing: DS.Space.s4) {
              Toggle(
                field.settingsTitle,
                isOn: Binding(
                  get: { draft.contains(field) },
                  set: { selected in
                    if selected { draft.insert(field) } else { draft.remove(field) }
                  })
              )
              .toggleStyle(.checkbox)
              .accessibilityHint(tr("\(valueLabel)：\(value)"))
              Spacer(minLength: 0)
              Text(value)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.trailing)
                .accessibilityHidden(true)
            }
            .dsFont(.sm)
          }
        }
      }
      if let failure { Text(verbatim: failure).foregroundStyle(DS.Palette.error) }
      HStack(spacing: DS.Space.s2) {
        Spacer()
        Button(tr("取消")) { dismiss() }
          .buttonStyle(DSButtonStyle(kind: .secondary))
          .keyboardShortcut(.cancelAction)
        Button(tr("保存"), action: save)
          .buttonStyle(DSButtonStyle(kind: .primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!sync.enabled || draft == preferences.selectedFields)
      }
    }
    .padding(DS.Space.s6)
    .frame(minWidth: 400, idealWidth: 460)
  }

  private func currentValue(_ field: Field) -> String {
    switch field {
    case .appearance: settings.appearance.title
    case .menuBarLayout: settings.menuBarLayout.title
    case .restSound: settings.restSound.title
    case .restEnabled: settings.restEnabled ? tr("开启") : tr("关闭")
    }
  }

  private func save() {
    do {
      try preferences.setSelectedFields(draft)
      dismiss()
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
  let editScope: () -> Void
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
      Text(decision.title).dsFont(.lg, weight: .semibold)
      if !fields.isEmpty {
        Text(tr("只列出不同的设置。选中的值将同步到参与的 Mac。"))
          .foregroundStyle(.secondary)
        let options = SettingsGroup {
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
            GroupRow(showsDivider: choice.id != fields.first?.id) {
              VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text(choice.field.settingsTitle).dsFont(.sm, weight: .semibold)
                if remoteValues.count == 1 {
                  ViewThatFits(in: .horizontal) {
                    picker.horizontalRadioGroupLayout().fixedSize()
                    picker
                  }
                } else {
                  picker
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
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
      HStack(spacing: DS.Space.s2) {
        Button(tr("选择同步项"), action: editScope)
          .buttonStyle(DSButtonStyle(kind: .ghost))
        Spacer()
        Button(tr("取消")) {
          switch decision {
          case .first: perform { try preferences.cancelFirst() }
          case .conflict: dismiss()
          }
        }
        .buttonStyle(DSButtonStyle(kind: .secondary))
        .keyboardShortcut(.cancelAction)
        Button(tr("应用并同步")) { confirm() }
          .buttonStyle(DSButtonStyle(kind: .primary))
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
