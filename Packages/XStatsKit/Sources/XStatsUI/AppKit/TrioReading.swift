// SPDX-License-Identifier: AGPL-3.0-or-later
import AIUsage
import Foundation
import Localization
import Metrics

/// 仅包含三个区域真正使用的标量；不观察历史数组或无关指标。
struct TrioReading: Equatable {
  var values: [TrioSource: Double] = [:]
  var connection: NetworkIconState = .unknown
  var charging = false
  var pluggedIn = false
  var fullyCharged = false
  var lowPower = false
  var muted = false
  var bluetoothOutput = false
  var audioPlaying = false
  var audioSymbol = "headphones"
  var audioName: String?
  var selectedBluetoothSymbol: String?
  var selectedBluetoothName: String?
  struct AIDot: Equatable {
    let name: String
    /// nil 表示当前没有有效额度，与剩余额度为零区分；每个服务保留固定位置。
    var fraction: Double?

    /// 按整百分比绘制扇形，向下取整保留 10%、20%、50% 的颜色分界。
    var imageFraction: Double? {
      guard let fraction, fraction.isFinite else { return nil }
      return floor(min(1, max(0, fraction)) * 100) / 100
    }
  }
  var aiDots: [AIDot] = []
  var keepAwake = false
  var fanFraction: Double?
  var loadSensitivity: LoadSensitivity = .standard

  init() {}

  @MainActor init(model: AppModel) {
    loadSensitivity = model.settings.loadSensitivity
    let configuration = model.settings.trio
    let items = Set(model.drawnMenuBarItems)
    for source in Set(configuration.sources) {
      guard let item = source.item, items.contains(item) else { continue }
      let value: Double? =
        switch source {
        case .cpu: model.store.cpu?.total
        case .memory: model.store.memory?.usedFraction
        case .disk: model.store.disk?.usedFraction
        case .battery: model.store.battery?.level
        case .audio: model.audio.output?.outputVolume
        case .fan: model.store.fastestFan?.current
        default: nil
        }
      if let value, value.isFinite, source != .fan || value >= 0 { values[source] = value }
      if source == .aiUsage {
        let menuQuotas = MenuBarReading(model: model, items: [.aiUsage]).aiQuotas
        if configuration.footer == .aiUsage {
          let names =
            model.aiUsage.usesMagpie
            ? model.aiUsage.availableMenuBarQuotaProviders.filter {
              model.settings.aiMenuBarProviders.contains($0)
            }
            : AIProviderID.allCases.filter { model.settings.aiUsageSources.contains($0) }.map(
              \.rawValue)
          aiDots = names.prefix(AppSettings.aiMenuBarProviderLimit).map { name in
            let quota = menuQuotas.first {
              ($0.magpieName ?? $0.provider?.rawValue) == name
            }
            let remaining = quota?.window.remainingPercent
            return AIDot(
              name: name,
              fraction: remaining.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil })
          }
        }
      }
    }
    if items.contains(.fan), let fan = model.store.fastestFan,
      fan.current.isFinite, fan.current >= 0, fan.maximum.isFinite, fan.maximum > 0
    {
      fanFraction = min(1, fan.current / fan.maximum)
    }
    if items.contains(.battery) {
      charging = model.store.battery?.isCharging == true
      pluggedIn = model.store.battery?.isPluggedIn == true
      fullyCharged = model.store.battery?.isFullyCharged == true
      lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    if items.contains(.network) { connection = model.store.network?.connection ?? .unknown }
    if items.contains(.audio) {
      let output = model.audio.output
      muted = output?.outputMuted == true
      bluetoothOutput = output?.outputKind == .bluetooth || output?.bluetoothAddress != nil
      audioPlaying = output?.isRunningOutput == true
      audioSymbol = AudioControlPresentation.outputSymbol(output, muted: false)
      audioName = output?.name
    }
    if items.contains(.network), configuration.bluetoothReplacesNetwork,
      let selectedID = configuration.bluetoothDeviceID,
      let device = model.bluetooth.devices?.first(where: {
        $0.isConnected && BluetoothDevicePreferences.key($0.address) == selectedID
      })
    {
      selectedBluetoothSymbol = device.kind.symbol
      selectedBluetoothName = device.name
    }
    keepAwake = model.keepAwake.isActive
  }

  /// 图像按显示粒度比较，原始读数仍用于提示；菜单栏和程序坞共用此规则。
  func hasSameImage(as other: Self, configuration: TrioConfiguration) -> Bool {
    guard keepAwake == other.keepAwake,
      outerFraction(configuration.outer) == other.outerFraction(configuration.outer)
    else { return false }
    if configuration.showsValue,
      shortValue(configuration.outer) != other.shortValue(configuration.outer)
        || batteryPowerSymbol(configuration) != other.batteryPowerSymbol(configuration)
    {
      return false
    }
    if configuration.center == .network || configuration.outer == .network {
      guard connection == other.connection,
        bluetoothReplacementSymbol(configuration) == other.bluetoothReplacementSymbol(configuration)
      else { return false }
    }
    if configuration.center != .none {
      guard centerSymbol(configuration) == other.centerSymbol(configuration) else { return false }
      if configuration.center != .network && configuration.center != .audio
        && configuration.center != .display,
        shortValue(configuration.center) != other.shortValue(configuration.center)
      {
        return false
      }
    }
    if configuration.statusColors, configuration.sources.contains(.battery) {
      guard
        values[.battery].map(LoadLevel.remaining)
          == other.values[.battery].map(LoadLevel.remaining),
        charging == other.charging, pluggedIn == other.pluggedIn, lowPower == other.lowPower
      else { return false }
    }
    // 圆弧按整百分比复用，但阈值两侧的颜色可能不同，必须额外比较负载档位。
    if configuration.statusColors,
      usageLevel(configuration.outer) != other.usageLevel(configuration.outer)
    {
      return false
    }
    if configuration.sources.contains(.audio) || configuration.followsBluetoothAudio {
      guard usesBlueVolume(configuration) == other.usesBlueVolume(configuration) else {
        return false
      }
    }
    if configuration.footer == .aiUsage {
      for index in 0..<4 {
        let fraction = aiDots.indices.contains(index) ? aiDots[index].imageFraction : nil
        let otherFraction =
          other.aiDots.indices.contains(index) ? other.aiDots[index].imageFraction : nil
        if fraction != otherFraction { return false }
      }
    } else {
      guard footerFraction(configuration) == other.footerFraction(configuration) else {
        return false
      }
      if configuration.footer == .audio, muted != other.muted { return false }
    }
    return true
  }

  func outerFraction(_ source: TrioSource) -> Double? {
    if source == .network {
      if connection == .unknown { return nil }
      return connection.isError ? 0 : 1
    }
    guard isProportional(source), let value = values[source], value.isFinite else { return nil }
    return (min(1, max(0, value)) * 100).rounded() / 100
  }

  func usageLevel(_ source: TrioSource) -> LoadLevel? {
    guard source == .cpu || source == .memory || source == .disk,
      let value = values[source], value.isFinite
    else { return nil }
    return LoadLevel.usage(value, sensitivity: loadSensitivity)
  }

  func footerFraction(_ configuration: TrioConfiguration) -> Double? {
    let raw = configuration.footer == .fan ? fanFraction : (muted ? 0 : values[.audio])
    guard let raw, raw.isFinite else { return nil }
    let value = min(1, max(0, raw))
    return configuration.footerStyle == .dots
      ? ceil(value * 4) / 4 : (value * 100).rounded() / 100
  }

  func centerSymbol(_ configuration: TrioConfiguration) -> String {
    guard configuration.center == .network else {
      if configuration.center == .audio { return audioSymbol }
      return configuration.center.item?.symbol ?? "minus"
    }
    if let symbol = bluetoothReplacementSymbol(configuration) { return symbol }
    return networkSymbol(configuration)
  }

  func bluetoothReplacementSymbol(_ configuration: TrioConfiguration) -> String? {
    guard configuration.center == .network, configuration.bluetoothReplacesNetwork,
      !configuration.networkErrorsFirst || !connection.isError
    else { return nil }
    if configuration.bluetoothDeviceID != nil { return selectedBluetoothSymbol }
    return bluetoothOutput ? audioSymbol : nil
  }

  func batteryPowerSymbol(_ configuration: TrioConfiguration) -> String? {
    guard configuration.outer == .battery, configuration.showsValue,
      let level = values[.battery], level.isFinite
    else { return nil }
    switch configuration.effectiveBatteryDisplay {
    case .value: return nil
    case .chargingSymbol: return charging ? "bolt.fill" : nil
    case .powerSymbol:
      if charging { return "bolt.fill" }
      return pluggedIn ? "powerplug.fill" : nil
    }
  }

  func usesBlueVolume(_ configuration: TrioConfiguration) -> Bool {
    configuration.bluetoothVolumeColor && bluetoothOutput && audioPlaying
  }

  func networkSymbol(_ configuration: TrioConfiguration) -> String {
    switch connection {
    case .wifi, .unassociated: "wifi"
    case .off, .unavailable: "wifi.slash"
    case .noInternet: "wifi.exclamationmark"
    case .ethernet: configuration.ethernetAsWiFi ? "wifi" : "network"
    case .hotspot: configuration.hotspotAsWiFi ? "wifi" : "personalhotspot"
    case .temporary:
      configuration.temporaryAsWiFi == true ? "wifi" : "point.3.connected.trianglepath.dotted"
    case .sharing: configuration.sharingAsWiFi == true ? "wifi" : "arrow.up.forward.app"
    case .unknown: "questionmark"
    }
  }

  var networkTitle: String {
    switch connection {
    case .wifi(let bars): tr("Wi-Fi 信号：\(bars) 格")
    case .unassociated: tr("Wi-Fi 已开启，未连接")
    case .off: tr("Wi-Fi 已关闭")
    case .unavailable: tr("Wi-Fi 不可用")
    case .noInternet: tr("无可用网络路由")
    case .ethernet: tr("有线连接")
    case .hotspot: tr("个人热点")
    case .temporary: tr("临时连接")
    case .sharing: tr("互联网共享")
    case .unknown: tr("暂无数据")
    }
  }

  func isProportional(_ source: TrioSource) -> Bool {
    [.cpu, .gpu, .memory, .disk, .battery, .audio, .aiUsage].contains(source)
  }

  func shortValue(_ source: TrioSource) -> String {
    guard let value = values[source] else { return "—" }
    if isProportional(source) {
      return (min(1, max(0, value)) * 100).rounded().formatted(
        .number.precision(.fractionLength(0)).locale(L10n.locale))
    }
    let number = value
    if source == .fan, number >= 1000 {
      return (number / 1000).formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))
        + "k"
    }
    return number.rounded().formatted(.number.precision(.fractionLength(0)).locale(L10n.locale))
  }

  func tooltip(_ configuration: TrioConfiguration) -> String {
    var lines: [String] = []
    let sources =
      [configuration.outer, configuration.center]
      + (configuration.footer == .aiUsage ? [] : [configuration.footer.source])
    for source in sources where source != .none {
      let detail: String
      if source == .network {
        detail = networkTitle
      } else if source == .audio {
        detail = [audioName, muted ? tr("静音") : values[source].map(Format.percent) ?? tr("暂无数据")]
          .compactMap { $0 }.joined(separator: " · ")
      } else if source == .fan {
        detail =
          values[source].map {
            $0.formatted(.number.precision(.fractionLength(0)).locale(L10n.locale)) + " RPM"
          } ?? tr("暂无数据")
      } else if isProportional(source) {
        detail = values[source].map(Format.percent) ?? tr("暂无数据")
      } else {
        detail =
          values[source].map {
            $0.formatted(.number.precision(.fractionLength(0)).locale(L10n.locale))
          } ?? tr("暂无数据")
      }
      lines.append(
        [source.title, detail].joined(
          separator: " · "))
    }
    if configuration.footer == .aiUsage {
      if aiDots.isEmpty {
        lines.append([TrioSource.aiUsage.title, tr("暂无数据")].joined(separator: " · "))
      }
      for dot in aiDots {
        let detail = dot.fraction.map { tr("剩余 \(Format.percent($0))") } ?? tr("暂无数据")
        lines.append([AIServiceBrand.title(dot.name), detail].joined(separator: " · "))
      }
    }
    if configuration.outer == .battery, values[.battery] != nil {
      if charging {
        lines.append(tr("充电中"))
      } else if fullyCharged {
        lines.append(tr("已充满"))
      } else if pluggedIn {
        lines.append(tr("已连接电源，未充电"))
      }
    }
    if bluetoothReplacementSymbol(configuration) != nil {
      if let name = configuration.bluetoothDeviceID == nil ? audioName : selectedBluetoothName {
        lines.append(name)
      }
    }
    if keepAwake { lines.append(tr("防止休眠")) }
    return lines.isEmpty ? "XStats" : lines.joined(separator: "\n")
  }
}
