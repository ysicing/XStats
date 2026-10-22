import Foundation
import SMC

/// 温度与风扇（只读，普通权限即可）。
public final class SensorSampler {
  private var smc: SMCConnection?
  private var fans: FanControl?
  private var detectedFanCount: Int?
  private var catalog: [TemperatureGroup: [SMCKey]] = [:]
  private var lastDiscovery: ContinuousClock.Instant?
  private var lastConnectionAttempt: ContinuousClock.Instant?
  private let discoverTemperatures: (() -> [TemperatureGroup: [SMCKey]])?
  private let openConnection: () -> SMCConnection?
  private let clock: () -> ContinuousClock.Instant

  public convenience init() {
    self.init(openConnection: { try? SMCConnection() })
  }

  init(
    openConnection: @escaping () -> SMCConnection?,
    clock: @escaping () -> ContinuousClock.Instant = { .now }
  ) {
    self.openConnection = openConnection
    self.clock = clock
    lastConnectionAttempt = clock()
    smc = openConnection()
    fans = smc.map(FanControl.init)
    discoverTemperatures = nil
  }

  init(discoverTemperatures: @escaping () -> [TemperatureGroup: [SMCKey]]) {
    smc = nil
    fans = nil
    self.discoverTemperatures = discoverTemperatures
    openConnection = { nil }
    clock = { .now }
  }

  func temperatureKeys(now: ContinuousClock.Instant = .now) -> [TemperatureGroup: [SMCKey]] {
    connectIfNeeded(now: now)
    // 首次枚举为空时沿现有采样限频重试；成功后不再扫描，不新增后台定时器。
    if lastDiscovery == nil || (catalog.isEmpty && lastDiscovery!.duration(to: now) >= .seconds(30))
    {
      lastDiscovery = now
      if let discoverTemperatures {
        catalog = discoverTemperatures()
      } else {
        catalog = smc.map(TemperatureCatalog.discover) ?? [:]
      }
    }
    return catalog
  }

  /// 只读一次风扇数量并缓存；读取失败返回 nil，由后续采样或下次启动重试。
  public func detectFanCount() -> Int? {
    connectIfNeeded(now: clock())
    guard detectedFanCount == nil, let smc else { return detectedFanCount }
    if let raw = smc.double(SMCKey("FNum")), let count = Int(exactly: raw), count >= 0 {
      detectedFanCount = count
    }
    return detectedFanCount
  }

  public func sample(
    groups: Set<TemperatureGroup> = Set(TemperatureGroup.allCases), includeFans: Bool = true
  ) -> SensorReadings? {
    let now = clock()
    if !groups.isEmpty || includeFans { connectIfNeeded(now: now) }
    let catalog = groups.isEmpty ? [:] : temperatureKeys(now: now)
    guard let smc else { return nil }
    // 硬件数量成功读到后复用；未知时随既有采样重试，不新增轮询。
    _ = detectFanCount()
    var summaries: [TemperatureSummary] = []
    for group in TemperatureGroup.allCases where groups.contains(group) {
      let values = (catalog[group] ?? []).compactMap(smc.double).filter(
        TemperatureCatalog.plausibleRange.contains)
      guard !values.isEmpty else { continue }
      summaries.append(
        TemperatureSummary(
          group: group,
          average: values.reduce(0, +) / Double(values.count),
          maximum: values.max() ?? 0,
          sensorCount: values.count))
    }
    return SensorReadings(
      temperatures: summaries,
      fans: includeFans && detectedFanCount != 0 ? (fans?.read() ?? []) : [],
      fanCount: detectedFanCount)
  }

  private func connectIfNeeded(now: ContinuousClock.Instant) {
    guard smc == nil, discoverTemperatures == nil,
      lastConnectionAttempt.map({ $0.duration(to: now) >= .seconds(30) }) ?? true
    else { return }
    // 温度发现、风扇采样与数量探测共用重连预算，只随已有需求重试。
    lastConnectionAttempt = now
    smc = openConnection()
    fans = smc.map(FanControl.init)
    if smc != nil { lastDiscovery = nil }
  }
}
