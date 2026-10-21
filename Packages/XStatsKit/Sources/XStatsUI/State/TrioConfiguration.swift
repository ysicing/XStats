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

/// 三个固定区域的内容独立于弹窗项目；选项随来源切换保留，便于用户返回原组合。
public struct TrioConfiguration: Codable, Equatable, Sendable {
  static let outerSources: [TrioSource] = [.battery, .cpu, .memory, .disk]
  public var outer: TrioSource = .battery
  public var center: TrioSource = .network
  public var footer: TrioFooterSource = .audio
  public var showsValue = true
  public var showsValueWhenPluggedIn = false
  public var statusColors = true
  public var footerStyle: TrioFooterStyle = .dots
  public var ethernetAsWiFi = false
  public var hotspotAsWiFi = false
  public var bluetoothReplacesNetwork = true
  public var networkErrorsFirst = true
  public var bluetoothVolumeColor = true
  var sources: [TrioSource] { [outer, center, footer.source] }

  /// 旧配置与备份统一收敛到三个区域的新职责，避免隐藏选项继续触发采集。
  var normalized: Self {
    var result = self
    if !Self.outerSources.contains(outer) { result.outer = .cpu }
    result.center = .network
    return result
  }
}

extension AppSettings {
  /// 选择新来源时沿用“加入菜单栏即启用功能”的约定；移除只停止该来源的展示。
  func enableTrioSources(_ sources: [TrioSource]) {
    let items = sources.compactMap(\.item)
    enabledMonitoringModules.formUnion(
      items.filter { $0 != .battery && $0 != .display }.compactMap(\.monitoringModule))
    if items.contains(.audio) || (items.contains(.network) && trio.bluetoothReplacesNetwork) {
      audioEnabled = true
    }
    if items.contains(.aiUsage) { aiUsageEnabled = true }
  }
}
