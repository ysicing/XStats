// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Localization

public enum TrioSource: String, Codable, CaseIterable, Identifiable, Sendable {
  case battery, network, audio, cpu, gpu, memory, disk, temperature, fan, display, aiUsage, none
  public var id: String { rawValue }
  var item: MenuBarItem? { MenuBarItem(rawValue: rawValue) }
  var title: String { item?.title ?? tr("不显示") }
}

/// 底部承载音量、风扇转速或 AI 额度；旧版的其他指标安全回退为音量。
public enum TrioFooterSource: String, Codable, CaseIterable, Identifiable, Sendable {
  case audio, fan, aiUsage
  public var id: String { rawValue }
  var source: TrioSource {
    switch self {
    case .audio: .audio
    case .fan: .fan
    case .aiUsage: .aiUsage
    }
  }
  var title: String { self == .audio ? tr("音量") : source.title }

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: value) ?? .audio
  }
}

public enum TrioFooterStyle: String, Codable, CaseIterable, Identifiable, Sendable {
  case dots, arc
  public var id: String { rawValue }
  var title: String { self == .dots ? tr("圆点") : tr("圆弧") }
}

public enum TrioBatteryDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
  case value, chargingSymbol, powerSymbol
  public var id: String { rawValue }
  var title: String {
    switch self {
    case .value: tr("始终显示电量")
    case .chargingSymbol: tr("充电时显示闪电，其余显示电量")
    case .powerSymbol: tr("充电时显示闪电，接电时显示插头")
    }
  }
}

/// 三个固定区域的内容独立于弹窗项目；选项随来源切换保留，便于用户返回原组合。
public struct TrioConfiguration: Codable, Equatable, Sendable {
  static let outerSources: [TrioSource] = [.battery, .cpu, .memory, .disk]
  public var outer: TrioSource = .battery
  public var center: TrioSource = .network
  public var footer: TrioFooterSource = .audio
  public var showsValue = true
  public var showsValueWhenPluggedIn = false
  /// 缺少新字段时按旧开关解释，避免升级改变原有的电源状态显示方式。
  public var batteryDisplay: TrioBatteryDisplay?
  public var batteryTopScale: Double?
  var effectiveBatteryDisplay: TrioBatteryDisplay {
    batteryDisplay ?? (showsValueWhenPluggedIn ? .value : .powerSymbol)
  }
  var effectiveBatteryTopScale: Double {
    guard let batteryTopScale, batteryTopScale.isFinite else { return 1 }
    return min(1.2, max(0.8, batteryTopScale))
  }
  public var statusColors = true
  public var footerStyle: TrioFooterStyle = .dots
  public var ethernetAsWiFi = false
  public var hotspotAsWiFi = false
  /// 新选项使用可选存储，旧配置缺少字段时仍保留原有组合与连接图标。
  public var temporaryAsWiFi: Bool?
  public var sharingAsWiFi: Bool?
  public var wifiIconScale: Double?
  var effectiveWiFiIconScale: Double {
    guard let wifiIconScale, wifiIconScale.isFinite else { return 1 }
    return min(1.2, max(0.8, wifiIconScale))
  }
  public var bluetoothReplacesNetwork = true
  public var networkErrorsFirst = true
  public var bluetoothVolumeColor = true
  /// nil 沿用旧版自动跟随音频输出；显式设备失联时不切到其他设备。
  public var bluetoothDeviceID: String?
  /// 可选存储让旧配置缺少此字段时仍能完整解码。
  public var bluetoothIconScale: Double?
  var effectiveBluetoothIconScale: Double {
    guard let bluetoothIconScale, bluetoothIconScale.isFinite else { return 1 }
    return min(1.2, max(0.8, bluetoothIconScale))
  }
  var followsBluetoothAudio: Bool { bluetoothReplacesNetwork && bluetoothDeviceID == nil }
  var sources: [TrioSource] { [outer, center, footer.source] }

  /// 旧配置与备份统一收敛到三个区域的新职责，避免隐藏选项继续触发采集。
  var normalized: Self {
    var result = self
    if !Self.outerSources.contains(outer) { result.outer = .cpu }
    result.center = .network
    if batteryTopScale != nil { result.batteryTopScale = effectiveBatteryTopScale }
    if wifiIconScale != nil { result.wifiIconScale = effectiveWiFiIconScale }
    if bluetoothIconScale != nil { result.bluetoothIconScale = effectiveBluetoothIconScale }
    return result
  }
}

extension AppSettings {
  /// 选择新来源时沿用“加入菜单栏即启用功能”的约定；移除只停止该来源的展示。
  func enableTrioSources(_ sources: [TrioSource]) {
    let items = sources.compactMap(\.item)
    enabledMonitoringModules.formUnion(
      items.filter { $0 != .battery && $0 != .display }.compactMap(\.monitoringModule))
    if items.contains(.audio) || (items.contains(.network) && trio.followsBluetoothAudio) {
      audioEnabled = true
    }
    if items.contains(.aiUsage) { aiUsageEnabled = true }
  }
}
