import Foundation
import Metrics
import Observation
import OSLog

/// 短暂休眠或切换到其他设备时保留最近电量；过期设备不会继续伪装成实时读数。
struct BluetoothDeviceCache {
  let retention: TimeInterval
  private var entries: [String: (device: BluetoothDevice, lastSeen: Date)] = [:]

  init(retention: TimeInterval = 30 * 60) {
    self.retention = retention
  }

  mutating func merge(current: [BluetoothDevice], now: Date) -> [BluetoothDevice] {
    entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) <= retention }
    let currentNameCounts = Dictionary(grouping: current, by: Self.normalizedName).mapValues(
      \.count)
    var currentKeys = Set<String>()
    var result: [BluetoothDevice] = []
    for var device in current.sorted(by: { $0.isConnected && !$1.isConnected }) {
      var key = Self.key(for: device)
      var migratedEntry: (device: BluetoothDevice, lastSeen: Date)?
      if entries[key] == nil, currentNameCounts[Self.normalizedName(device)] == 1 {
        let candidates = entries.filter {
          Self.normalizedName($0.value.device) == Self.normalizedName(device)
            && (device.address.isEmpty || $0.value.device.address.isEmpty)
        }
        if candidates.count == 1, let previous = candidates.first {
          migratedEntry = previous.value
          entries[previous.key] = nil
          if device.address.isEmpty { device.address = previous.value.device.address }
          key = Self.key(for: device)
        }
      }
      currentKeys.insert(key)
      if device.isConnected {
        device.lastSeen = nil
        entries[key] = (device, now)
        result.append(device)
      } else if let cached = entries[key] ?? migratedEntry {
        var recent = cached.device
        recent.name = device.name
        recent.address = device.address
        recent.kind = device.kind
        recent.isConnected = false
        recent.isCharging = nil
        recent.lastSeen = cached.lastSeen
        result.append(recent)
      } else {
        device.lastSeen = nil
        result.append(device)
      }
    }

    for (key, entry) in entries where !currentKeys.contains(key) {
      var device = entry.device
      device.isConnected = false
      device.isCharging = nil
      device.lastSeen = entry.lastSeen
      result.append(device)
    }
    return result.sorted {
      if $0.isConnected != $1.isConnected { return $0.isConnected }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private static func key(for device: BluetoothDevice) -> String {
    device.id
  }

  private static func normalizedName(_ device: BluetoothDevice) -> String {
    device.name.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
}

/// 电量读取需要启动 system_profiler；只按展示需求监听连接事件，并以低频轮询兜底。
@MainActor
@Observable
public final class BluetoothController {
  public enum Demand: Equatable, Sendable {
    /// 不轮询
    case off
    /// 菜单栏需要（电量低提示、没有电池的 Mac 显示设备电量）：每 5 分钟
    case background
    /// 电池弹窗 / 页面、本机信息页打开着：每分钟
    case foreground

    var interval: Duration? {
      switch self {
      case .off: nil
      case .background: .seconds(300)
      case .foreground: .seconds(60)
      }
    }
  }

  /// nil 表示还没读过
  public private(set) var devices: [BluetoothDevice]?
  public private(set) var updatedAt: Date?
  public private(set) var isReading = false
  @ObservationIgnored private var demand: Demand = .off
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var deviceCache = BluetoothDeviceCache()
  @ObservationIgnored private var readingTask: Task<Void, Never>?
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private let events: any BluetoothConnectionObserving
  @ObservationIgnored private let eventDelay: Duration
  @ObservationIgnored private let minimumEventInterval: Duration
  @ObservationIgnored private var lastReadStarted: ContinuousClock.Instant?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var paused = false
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var observingEvents = false
  @ObservationIgnored private var eventAvailability: Bool?
  private static let logger = Logger(subsystem: Log.subsystem, category: "bluetooth")
  @ObservationIgnored var readDevices: () async -> [BluetoothDevice] = {
    let worker = Task.detached(priority: .utility) { BluetoothBatteryReader.read() }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  init(
    events: any BluetoothConnectionObserving = BluetoothConnectionObserver(),
    eventDelay: Duration = .seconds(1), minimumEventInterval: Duration = .seconds(5)
  ) {
    self.events = events
    self.eventDelay = eventDelay
    self.minimumEventInterval = minimumEventInterval
  }

  isolated deinit {
    task?.cancel()
    eventTask?.cancel()
    readingTask?.cancel()
    events.stop()
  }

  /// 电量最低的一块电池（耳机的左右耳、充电盒分别算）
  public var lowest: (device: BluetoothDevice, label: String, percent: Int)? {
    Self.lowest(in: devices ?? [])
  }

  static func lowest(in devices: [BluetoothDevice]) -> (
    device: BluetoothDevice, label: String, percent: Int
  )? {
    var best: (device: BluetoothDevice, label: String, percent: Int)?
    for device in devices where device.isConnected {
      for battery in device.batteries {
        if let current = best, battery.percent >= current.percent { continue }
        best = (device, battery.label, battery.percent)
      }
    }
    return best
  }

  func setDemand(_ demand: Demand) {
    guard !stopped, demand != self.demand else { return }
    self.demand = demand
    task?.cancel()
    task = nil
    guard let interval = demand.interval, !paused else {
      suspend()
      return
    }
    let epoch = generation
    if !observingEvents {
      observingEvents = events.start { [weak self] in self?.connectionChanged(generation: epoch) }
      if eventAvailability != observingEvents {
        if observingEvents {
          Self.logger.debug("蓝牙连接事件监听已启用")
        } else {
          Self.logger.debug("蓝牙连接事件不可用，保留按需低频轮询")
        }
        eventAvailability = observingEvents
      }
    }
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let delay = self?.fallbackDelay(interval: interval) else { return }
        if delay > .zero {
          do {
            try await Task.sleep(for: delay, tolerance: interval / 10)
          } catch { return }
        } else {
          let reading = self?.beginRead()
          await reading?.value
        }
      }
    }
  }

  func setPaused(_ paused: Bool) {
    guard self.paused != paused, !stopped else { return }
    self.paused = paused
    if paused {
      suspend()
    } else {
      let demand = self.demand
      self.demand = .off
      setDemand(demand)
    }
  }

  func stop() {
    stopped = true
    demand = .off
    suspend()
  }

  private func suspend() {
    generation &+= 1
    task?.cancel()
    task = nil
    eventTask?.cancel()
    eventTask = nil
    // 保留取消中的读取句柄，直到真实工作退出，快速重新开启也不会重叠启动子进程。
    readingTask?.cancel()
    lastReadStarted = nil
    isReading = false
    events.stop()
    if observingEvents { Self.logger.debug("蓝牙连接事件监听已停止") }
    observingEvents = false
    eventAvailability = nil
  }

  private func fallbackDelay(interval: Duration) -> Duration? {
    guard !paused, !stopped, demand != .off else { return nil }
    guard let lastReadStarted else { return .zero }
    return max(.zero, interval - lastReadStarted.duration(to: .now))
  }

  private func connectionChanged(generation epoch: Int) {
    guard epoch == generation, !paused, !stopped, demand != .off, eventTask == nil else { return }
    let eventDelay = eventDelay
    eventTask = Task { [weak self] in
      do {
        // 固定窗口合并突发事件；在途读取结束后再读，避免把旧采样当成事件后的新状态。
        try await Task.sleep(for: eventDelay, tolerance: eventDelay / 5)
        let reading = self?.readingTask
        await reading?.value
        guard !Task.isCancelled, let delay = self?.eventReadDelay() else { return }
        if delay > .zero { try await Task.sleep(for: delay, tolerance: .milliseconds(100)) }
      } catch { return }
      guard !Task.isCancelled, let self, self.generation == epoch else { return }
      self.eventTask = nil
      _ = self.beginRead()
    }
  }

  private func eventReadDelay() -> Duration {
    guard let lastReadStarted else { return .zero }
    return max(.zero, minimumEventInterval - lastReadStarted.duration(to: .now))
  }

  /// 供低电量提醒复用：读数足够新时直接返回，否则读一次并更新共享缓存。
  /// 返回值可能含缓存中已断开的设备，调用方需按 isConnected 过滤。
  func recentDevices(maxAge: TimeInterval, now: Date = Date()) async -> [BluetoothDevice] {
    guard !paused, !stopped, !Task.isCancelled else { return devices ?? [] }
    if let updatedAt, now.timeIntervalSince(updatedAt) < maxAge, let devices { return devices }
    await beginRead()?.value
    return devices ?? []
  }

  /// 弹窗里的刷新按钮
  func refresh() {
    _ = beginRead()
  }

  private func beginRead() -> Task<Void, Never>? {
    guard !paused, !stopped, !Task.isCancelled else { return nil }
    // 提醒和界面共享同一次采样，等待缓存合并完成再返回，不能因正在读取就返回旧值。
    if let readingTask {
      return readingTask
    }
    isReading = true
    lastReadStarted = .now
    let epoch = generation
    let read = readDevices
    let reading = Task { [weak self] in
      let current = await read()
      guard let self else { return }
      defer {
        self.isReading = false
        self.readingTask = nil
      }
      guard !Task.isCancelled, self.generation == epoch else { return }
      let now = Date()
      self.devices = self.deviceCache.merge(current: current, now: now)
      self.updatedAt = now
    }
    readingTask = reading
    return reading
  }
}

extension BluetoothDevice.Kind {
  /// 列表与菜单栏里代表设备类型的图标
  var symbol: String {
    switch self {
    case .keyboard: "keyboard"
    case .mouse: "computermouse"
    case .trackpad: "rectangle.and.hand.point.up.left"
    case .headphones: "headphones"
    case .phone: "iphone"
    case .other: "dot.radiowaves.left.and.right"
    }
  }
}
