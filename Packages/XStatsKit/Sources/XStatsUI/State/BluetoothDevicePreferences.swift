// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import SwiftUI

/// 只保存完整硬件地址，不以名称建立持久关联；展示偏好不改变采集、连接或低电量告警。
struct BluetoothDevicePreferences: Codable, Equatable, Sendable {
  private(set) var pinned: [String] = []
  private(set) var hidden: Set<String> = []

  static func key(_ address: String) -> String? {
    let key = address.lowercased().replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: "-", with: "")
    return key.count == 12 && key.allSatisfy { "0123456789abcdef".contains($0) } ? key : nil
  }

  init() {}

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let savedPins = try values.decode([String].self, forKey: .pinned)
    var seen = Set<String>()
    pinned = savedPins.prefix(256).compactMap(Self.key).filter { seen.insert($0).inserted }
    hidden = Set(try values.decode([String].self, forKey: .hidden).prefix(256).compactMap(Self.key))
  }

  mutating func togglePin(_ address: String) {
    guard let key = Self.key(address) else { return }
    if pinned.contains(key) {
      pinned.removeAll { $0 == key }
    } else if pinned.count < 256 {
      pinned.append(key)
      hidden.remove(key)
    }
  }

  mutating func toggleHidden(_ address: String) {
    guard let key = Self.key(address) else { return }
    if hidden.contains(key) {
      hidden.remove(key)
    } else if hidden.count < 256 {
      hidden.insert(key)
      pinned.removeAll { $0 == key }
    }
  }

  mutating func revealAll() { hidden.removeAll() }

  func arranged<Device>(
    _ devices: [Device], address: (Device) -> String, keeping: Set<String> = []
  ) -> [Device] {
    let ranks = Dictionary(
      uniqueKeysWithValues: pinned.enumerated().map { ($0.element, $0.offset) })
    return devices.enumerated().filter { _, device in
      guard let key = Self.key(address(device)) else { return true }
      return !hidden.contains(key) || keeping.contains(key)
    }.sorted { lhs, rhs in
      let left = Self.key(address(lhs.element)).flatMap { ranks[$0] } ?? Int.max
      let right = Self.key(address(rhs.element)).flatMap { ranks[$0] } ?? Int.max
      return left == right ? lhs.offset < rhs.offset : left < right
    }.map(\.element)
  }
}

struct BluetoothDeviceChoice: Identifiable, Sendable {
  let id: String
  let name: String
  init?(address: String, name: String) {
    guard let id = BluetoothDevicePreferences.key(address) else { return nil }
    self.id = id
    self.name = name
  }

  static func unique(_ choices: [Self]) -> [Self] {
    var seen = Set<String>()
    return choices.filter { seen.insert($0.id).inserted }
  }
}

/// 本机信息页与电池弹窗共用管理入口；没有稳定地址的设备仍展示，但不保存名称偏好。
struct BluetoothDeviceMenu: View {
  let devices: [BluetoothDeviceChoice]
  @Environment(AppModel.self) private var model

  var body: some View {
    Menu {
      ForEach(devices) { @Sendable device in
        BluetoothDeviceMenuEntry(device: device)
      }
      if !model.settings.bluetoothDevicePreferences.hidden.isEmpty {
        Divider()
        Button(tr("显示所有隐藏设备")) { model.settings.bluetoothDevicePreferences.revealAll() }
      }
    } label: {
      Label(tr("管理蓝牙设备"), systemImage: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton).fixedSize()
    .accessibilityIdentifier("bluetooth.manageDevices")
  }
}

private struct BluetoothDeviceMenuEntry: View {
  let device: BluetoothDeviceChoice

  nonisolated init(device: BluetoothDeviceChoice) { self.device = device }

  var body: some View {
    Menu {
      BluetoothDeviceActions(device: device)
    } label: {
      Text(verbatim: device.name)
    }
  }
}

/// 管理菜单与设备行右键菜单使用相同操作，避免两处的置顶、隐藏行为不一致。
struct BluetoothDeviceActions: View {
  let device: BluetoothDeviceChoice
  @Environment(AppModel.self) private var model

  nonisolated init(device: BluetoothDeviceChoice) { self.device = device }

  var body: some View {
    Group {
      Button(
        model.settings.bluetoothDevicePreferences.pinned.contains(device.id)
          ? tr("取消置顶") : tr("置顶设备")
      ) { model.settings.bluetoothDevicePreferences.togglePin(device.id) }
      Button(
        model.settings.bluetoothDevicePreferences.hidden.contains(device.id)
          ? tr("显示设备") : tr("隐藏设备")
      ) { model.settings.bluetoothDevicePreferences.toggleHidden(device.id) }
    }
  }
}
