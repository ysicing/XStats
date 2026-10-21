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
    SettingsGroup(caption: tr("图标外观")) {
      GroupRow {
        SettingRow(title: tr("顶部显示数值")) {
          DSToggle(isOn: $settings.trio.showsValue, label: tr("顶部显示数值"))
        }
      }
      if config.sources.contains(.battery) {
        GroupRow {
          SettingRow(title: tr("电池状态颜色")) {
            DSToggle(isOn: $settings.trio.statusColors, label: tr("电池状态颜色"))
          }
        }
      }
      if config.outer == .battery {
        GroupRow {
          SettingRow(title: tr("接通电源时显示数值")) {
            DSToggle(isOn: $settings.trio.showsValueWhenPluggedIn, label: tr("接通电源时显示数值"))
              .disabled(!config.showsValue)
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
    if config.sources.contains(.network) || config.sources.contains(.audio) {
      SettingsGroup(caption: tr("连接与音频")) {
        if config.center == .network {
          GroupRow {
            SettingRow(title: tr("蓝牙音频替换网络图标")) {
              DSToggle(isOn: $settings.trio.bluetoothReplacesNetwork, label: tr("蓝牙音频替换网络图标"))
            }
          }
          if config.bluetoothReplacesNetwork {
            GroupRow {
              SettingRow(title: tr("网络异常时优先显示网络")) {
                DSToggle(isOn: $settings.trio.networkErrorsFirst, label: tr("网络异常时优先显示网络"))
              }
            }
          }
        }
        if config.sources.contains(.network) {
          GroupRow {
            SettingRow(title: tr("有线连接使用 Wi-Fi 图标")) {
              DSToggle(isOn: $settings.trio.ethernetAsWiFi, label: tr("有线连接使用 Wi-Fi 图标"))
            }
          }
          GroupRow {
            SettingRow(title: tr("个人热点使用 Wi-Fi 图标")) {
              DSToggle(isOn: $settings.trio.hotspotAsWiFi, label: tr("个人热点使用 Wi-Fi 图标"))
            }
          }
        }
        if config.sources.contains(.audio)
          || (config.center == .network && config.bluetoothReplacesNetwork)
        {
          GroupRow(showsDivider: false) {
            SettingRow(title: tr("蓝牙播放时使用蓝色")) {
              DSToggle(isOn: $settings.trio.bluetoothVolumeColor, label: tr("蓝牙播放时使用蓝色"))
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
