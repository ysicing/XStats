// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct SyncSettingsPage: View {
  @Environment(AppModel.self) private var model
  @State private var sheet: Sheet?
  @State private var retry = 0
  @State private var completedLoad: PreferenceLoad?

  private var sync: ActivitySyncController { model.activity.sync }
  private var localID: UUID { model.activity.deviceID }

  var body: some View {
    Group {
      if sync.enabled {
        enabledPage
      } else {
        PageScroll {
          SettingsGroup {
            GroupRow(showsDivider: false) {
              SettingRow(title: tr("同步"), subtitle: tr("未开启"), icon: PanelTab.settingsSync.symbol) {
                Button(tr("可选功能")) {
                  model.featureSettingsTab = .optional
                  model.settings.panelTab = .settingsFeatures
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
              }
            }
          }
        }
      }
    }
    .onChange(of: sync.preferences != nil) { _, available in
      if !available { dismissPreferenceSheet() }
    }
  }

  private var enabledPage: some View {
    let load = PreferenceLoad(destinationID: sync.destinationID, retry: retry)
    let devices = Self.devices(
      sync.preferences?.devices ?? [], localID: localID, localName: model.activity.deviceName,
      lastSettingsSyncAt: sync.preferences?.lastSettingsSyncAt)
    let names = Dictionary(
      uniqueKeysWithValues: devices.compactMap { device in
        device.name.map { (device.id, $0) }
      })
    let localActivityReceipt = devices.first?.lastActivitySyncAt
    let settingsScope = tr("外观、菜单栏布局和休息提醒偏好")

    return PageScroll {
      locationSettings
      SettingsGroup(caption: tr("同步内容")) {
        GroupRow(showsDivider: false) {
          detailRow(
            title: tr("应用活动"),
            subtitle: tr("汇总各台 Mac 的活动记录"),
            icon: PanelTab.activity.symbol,
            status: model.settings.activityFeatureEnabled
              ? Self.receipt(localActivityReceipt) : tr("未开启")
          ) { sheet = .activity }
        }
        GroupRow {
          if sync.preferences != nil {
            detailRow(
              title: tr("功能设置"), subtitle: settingsScope, icon: "slider.horizontal.3",
              status: preferenceStatus
            ) { sheet = .preferences }
          } else {
            SettingRow(title: tr("功能设置"), subtitle: settingsScope, icon: "slider.horizontal.3") {
              if completedLoad == load {
                Text(tr("无法读取同步设置")).foregroundStyle(.secondary)
                Button(tr("重试")) { retry += 1 }
                  .buttonStyle(DSButtonStyle(kind: .secondary))
              } else {
                ProgressView().controlSize(.small)
                  .accessibilityLabel(tr("正在读取同步设置"))
              }
            }
          }
        }
      }
      SettingsGroup(caption: tr("同步设备")) {
        ForEach(devices) { device in
          GroupRow(showsDivider: device.id != localID) {
            let latest = [device.lastActivitySyncAt, device.lastSettingsSyncAt].compactMap { $0 }
              .max()
            detailRow(
              title: ActivityPageFormat.deviceName(device.id, localID: localID, names: names),
              subtitle: device.id == localID && device.name != nil ? tr("本机") : nil,
              icon: Self.deviceIcon(device.name),
              status: latest == nil
                && sync.preferences?.devices.contains(where: { $0.id == device.id }) == true
                ? tr("已加入同步") : Self.receipt(latest)
            ) { sheet = .device(device.id) }
          }
        }
      }
      syncActions
    }
    .task(id: load) {
      await sync.preparePreferences()
      guard !Task.isCancelled, load.destinationID == sync.destinationID else { return }
      completedLoad = load
    }
    .onChange(of: sync.destinationID) {
      dismissPreferenceSheet()
    }
    .sheet(item: $sheet) { presented in
      switch presented {
      case .storage:
        ActivitySyncSettings(controller: sync)
      case .activity:
        detailSheet(title: tr("应用活动")) {
          LabeledContent(
            tr("本机记录"), value: model.settings.activityFeatureEnabled ? tr("开启") : tr("关闭"))
          LabeledContent(tr("存储位置"), value: sync.provider.settingsTitle)
          LabeledContent(tr("最近同步"), value: Self.dateLabel(localActivityReceipt))
          Button(tr("实验性功能")) {
            sheet = nil
            model.featureSettingsTab = .experimental
            model.settings.panelTab = .settingsFeatures
          }
        }
      case .preferences:
        if let preferences = sync.preferences {
          SyncPreferenceSettings(preferences: preferences, sync: sync, settings: model.settings)
            .id(preferences.selectedID)
        }
      case .device(let id):
        detailSheet(title: ActivityPageFormat.deviceName(id, localID: localID, names: names)) {
          if let device = devices.first(where: { $0.id == id }) {
            LabeledContent(tr("存储位置"), value: sync.provider.settingsTitle)
            LabeledContent(tr("应用活动"), value: Self.dateLabel(device.lastActivitySyncAt))
            LabeledContent(tr("功能设置"), value: Self.dateLabel(device.lastSettingsSyncAt))
          }
        }
      }
    }
  }

  private func dismissPreferenceSheet() {
    switch sheet {
    case .preferences, .device: sheet = nil
    case .storage, .activity, nil: break
    }
  }

  private var locationSettings: some View {
    SettingsGroup {
      GroupRow(showsDivider: false) {
        SettingRow(title: tr("存储位置"), subtitle: sync.provider.settingsTitle, icon: "cloud") {
          Button(tr("更改…")) { sheet = .storage }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(sync.syncing || sync.changingKey)
        }
      }
      GroupRow {
        SettingRow(title: tr("同步频率"), icon: "clock") {
          Picker(
            tr("同步频率"),
            selection: Binding(get: { sync.intervalMinutes }, set: sync.setIntervalMinutes)
          ) {
            ForEach([5, 10, 30, 60], id: \.self) { minutes in
              let value = minutes.formatted(.number.locale(L10n.locale))
              Text(tr("每 \(value) 分钟")).tag(minutes)
            }
            Text(tr("仅手动")).tag(0)
          }
          .pickerStyle(.menu)
          .labelsHidden()
        }
      }
    }
  }

  private var preferenceStatus: String {
    guard let preferences = sync.preferences, preferences.isEnabled else { return tr("未开启") }
    if preferences.firstChoice != nil || !preferences.conflicts.isEmpty { return tr("查看差异") }
    guard let date = preferences.lastSettingsSyncAt else { return tr("等待首次同步") }
    return Self.receipt(date)
  }

  private var syncActions: some View {
    HStack(spacing: DS.Space.s2) {
      if sync.syncing {
        ProgressView().controlSize(.small)
        Text(tr("正在同步…")).foregroundStyle(.secondary)
        if sync.syncMode == .manual {
          Button(tr("取消"), action: sync.cancelManualSync)
            .buttonStyle(DSButtonStyle(kind: .secondary))
        }
      } else {
        Button(tr("立即同步"), action: sync.syncNow)
          .buttonStyle(DSButtonStyle(kind: .primary))
          .disabled(!sync.active || sync.changingKey)
      }
      if let message = sync.message, !sync.syncing {
        Text(verbatim: message)
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }

  private func detailRow(
    title: String, subtitle: String?, icon: String, status: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      SettingRow(title: title, subtitle: subtitle, icon: icon) {
        Text(status).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          .multilineTextAlignment(.trailing)
        Image(systemName: "chevron.forward")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func detailSheet<Content: View>(
    title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      Text(title).font(.headline)
      Form { content() }
      HStack {
        Spacer()
        Button(tr("完成")) { sheet = nil }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(DS.Space.s6)
    .frame(minWidth: 400)
  }

  static func devices(
    _ devices: [SyncPreferences.Device], localID: UUID, localName: String?,
    lastSettingsSyncAt: Date?
  ) -> [SyncPreferences.Device] {
    let knownLocal = devices.first { $0.id == localID }
    let local = SyncPreferences.Device(
      id: localID, name: localName ?? knownLocal?.name,
      lastActivitySyncAt: knownLocal?.lastActivitySyncAt,
      lastSettingsSyncAt: lastSettingsSyncAt ?? knownLocal?.lastSettingsSyncAt)
    return [local] + devices.filter { $0.id != localID }
  }

  static func deviceIcon(_ name: String?) -> String {
    let model = name?.lowercased() ?? ""
    if model.contains("macbook") { return "laptopcomputer" }
    if model.contains("mac mini") || model.contains("macmini") { return "macmini" }
    if model.contains("mac studio") || model.contains("macstudio") { return "macstudio" }
    return "desktopcomputer"
  }

  private static func dateLabel(_ date: Date?) -> String {
    guard let date else { return tr("尚未同步") }
    return date.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale))
  }

  private static func receipt(_ date: Date?) -> String {
    guard let date else { return tr("尚未同步") }
    let value = dateLabel(date)
    return tr("最近同步 \(value)")
  }

  private struct PreferenceLoad: Hashable {
    let destinationID: String?
    let retry: Int
  }

  private enum Sheet: Hashable, Identifiable {
    case storage, activity, preferences
    case device(UUID)
    var id: Self { self }
  }
}

extension ActivitySyncProvider {
  var settingsTitle: String {
    switch self {
    case .iCloud: "iCloud Drive"
    case .webDAV: "WebDAV"
    case .googleDrive: "Google Drive"
    }
  }
}
