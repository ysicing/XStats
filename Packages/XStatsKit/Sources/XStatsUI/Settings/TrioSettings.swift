// SPDX-License-Identifier: AGPL-3.0-or-later
import Localization
import SwiftUI

/// 控件的排列与图标的三个固定区域对应；改变来源不改写弹窗项目。
struct TrioSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings
    let config = settings.trio
    SettingsGroup(caption: tr("三合一内容")) {
      GroupRow { sourcePicker(tr("外环与顶部"), selection: $settings.trio.outer) }
      GroupRow {
        SettingRow(title: tr("中部")) {
          Text(tr("网络")).foregroundStyle(DS.Palette.textSecondary)
        }
      }
      GroupRow(showsDivider: false) {
        SettingRow(title: tr("底部")) {
          Picker(tr("底部"), selection: $settings.trio.footer) {
            ForEach(
              TrioFooterSource.allCases.filter {
                $0 != .fan || model.store.supportsFans
                  || (model.store.fanCount == nil && config.footer == .fan)
              }
            ) { Text($0.title).tag($0) }
          }.labelsHidden().fixedSize()
        }
      }
    }
    if config.outer != .battery || config.footer != .aiUsage {
      SettingsGroup(caption: tr("图标外观")) {
        if config.outer != .battery {
          GroupRow(showsDivider: config.footer != .aiUsage) {
            SettingRow(title: tr("顶部显示数值")) {
              DSToggle(isOn: $settings.trio.showsValue, label: tr("顶部显示数值"))
            }
          }
        }
        if config.footer != .aiUsage {
          GroupRow(showsDivider: false) {
            SettingRow(title: tr("底部样式")) {
              Picker(tr("底部样式"), selection: $settings.trio.footerStyle) {
                ForEach(TrioFooterStyle.allCases) { Text($0.title).tag($0) }
              }.labelsHidden().fixedSize()
            }
          }
        }
      }
    }
    if config.outer == .battery {
      SettingsGroup(caption: tr("电池图标")) {
        GroupRow {
          SettingRow(title: tr("显示顶部内容")) {
            DSToggle(isOn: $settings.trio.showsValue, label: tr("显示顶部内容"))
          }
        }
        if config.showsValue {
          GroupRow {
            SettingRow(title: tr("电源状态显示")) {
              Picker(
                tr("电源状态显示"),
                selection: Binding(
                  get: { settings.trio.effectiveBatteryDisplay },
                  set: {
                    settings.trio.batteryDisplay = $0
                    settings.trio.showsValueWhenPluggedIn = $0 == .value
                  })
              ) {
                ForEach(TrioBatteryDisplay.allCases) { Text($0.title).tag($0) }
              }.labelsHidden().frame(maxWidth: 380)
            }
          }
          GroupRow {
            SettingRow(title: tr("电量数字与符号大小")) {
              HStack(spacing: DS.Space.s2) {
                Slider(
                  value: Binding(
                    get: { settings.trio.effectiveBatteryTopScale },
                    set: { settings.trio.batteryTopScale = $0 }),
                  in: 0.8...1.2, step: 0.05
                )
                .accessibilityLabel(tr("电量数字与符号大小"))
                .frame(width: 130)
                Text(config.effectiveBatteryTopScale.formatted(.percent.locale(L10n.locale)))
                  .monospacedDigit()
                  .frame(minWidth: 45, alignment: .trailing)
              }
            }
          }
        }
        GroupRow(showsDivider: false) {
          SettingRow(title: tr("电池状态颜色")) {
            DSToggle(isOn: $settings.trio.statusColors, label: tr("电池状态颜色"))
          }
        }
      }
    }
    if config.sources.contains(.network) {
      SettingsGroup(caption: tr("网络图标")) {
        GroupRow {
          SettingRow(title: tr("Wi-Fi 图标大小")) {
            HStack(spacing: DS.Space.s2) {
              Slider(
                value: Binding(
                  get: { settings.trio.effectiveWiFiIconScale },
                  set: { settings.trio.wifiIconScale = $0 }),
                in: 0.8...1.2, step: 0.05
              )
              .accessibilityLabel(tr("Wi-Fi 图标大小"))
              .frame(width: 130)
              Text(config.effectiveWiFiIconScale.formatted(.percent.locale(L10n.locale)))
                .monospacedDigit()
                .frame(minWidth: 45, alignment: .trailing)
            }
          }
        }
        GroupRow {
          SettingRow(title: tr("有线连接使用 Wi-Fi 图标")) {
            DSToggle(isOn: $settings.trio.ethernetAsWiFi, label: tr("有线连接使用 Wi-Fi 图标"))
          }
        }
        GroupRow {
          SettingRow(title: tr("临时连接使用 Wi-Fi 图标")) {
            DSToggle(
              isOn: Binding(
                get: { settings.trio.temporaryAsWiFi == true },
                set: { settings.trio.temporaryAsWiFi = $0 }),
              label: tr("临时连接使用 Wi-Fi 图标"))
          }
        }
        GroupRow(showsDivider: false) {
          SettingRow(title: tr("互联网共享使用 Wi-Fi 图标")) {
            DSToggle(
              isOn: Binding(
                get: { settings.trio.sharingAsWiFi == true },
                set: { settings.trio.sharingAsWiFi = $0 }),
              label: tr("互联网共享使用 Wi-Fi 图标"))
          }
        }
      }
      SettingsGroup(caption: tr("蓝牙图标")) {
        if config.center == .network {
          GroupRow {
            SettingRow(title: tr("蓝牙设备替换网络图标")) {
              DSToggle(isOn: $settings.trio.bluetoothReplacesNetwork, label: tr("蓝牙设备替换网络图标"))
            }
          }
          if config.bluetoothReplacesNetwork {
            GroupRow {
              SettingRow(
                title: tr("替换图标使用的设备"),
                subtitle: tr("仅改变图标，音量仍跟随当前输出；指定设备断开后显示网络图标。")
              ) {
                let choices = BluetoothDeviceChoice.unique(
                  (model.bluetooth.devices ?? []).compactMap {
                    BluetoothDeviceChoice(
                      address: $0.address,
                      name: $0.isConnected ? $0.name : tr("\($0.name) · 未连接"))
                  })
                Picker(tr("替换图标使用的设备"), selection: $settings.trio.bluetoothDeviceID) {
                  Text(tr("自动跟随音频输出")).tag(String?.none)
                  ForEach(choices) { device in
                    Text(verbatim: device.name).tag(Optional(device.id))
                  }
                  if let id = config.bluetoothDeviceID, !choices.contains(where: { $0.id == id }) {
                    Text(tr("所选设备不可用")).tag(Optional(id))
                  }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
              }
            }
            GroupRow {
              SettingRow(title: tr("蓝牙图标大小")) {
                HStack(spacing: DS.Space.s2) {
                  Slider(
                    value: Binding(
                      get: { settings.trio.effectiveBluetoothIconScale },
                      set: { settings.trio.bluetoothIconScale = $0 }),
                    in: 0.8...1.2, step: 0.05
                  )
                  .accessibilityLabel(tr("蓝牙图标大小"))
                  .frame(width: 130)
                  Text(config.effectiveBluetoothIconScale.formatted(.percent.locale(L10n.locale)))
                    .monospacedDigit()
                    .frame(minWidth: 45, alignment: .trailing)
                }
              }
            }
            GroupRow {
              SettingRow(title: tr("网络异常时优先显示网络")) {
                DSToggle(isOn: $settings.trio.networkErrorsFirst, label: tr("网络异常时优先显示网络"))
              }
            }
            GroupRow(showsDivider: false) {
              SettingRow(title: tr("蓝牙播放时使用蓝色")) {
                DSToggle(isOn: $settings.trio.bluetoothVolumeColor, label: tr("蓝牙播放时使用蓝色"))
              }
            }
          }
        }
      }
    }
    if config.footer == .aiUsage {
      SettingsGroup(caption: tr("AI 用量")) {
        GroupRow(showsDivider: false) {
          if model.aiUsage.usesMagpie {
            AIQuotaMenuBarSelection()
          } else {
            Text(tr("订阅额度"))
              .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
          }
        }
      }
    }
  }

  private func sourcePicker(_ title: String, selection: Binding<TrioSource>) -> some View {
    SettingRow(title: title) {
      Picker(title, selection: selection) {
        ForEach(
          TrioConfiguration.outerSources.filter {
            $0 != .battery || model.store.battery != nil
          }
        ) { source in
          Text(source.title).tag(source)
        }
      }.labelsHidden().fixedSize()
    }
  }
}
