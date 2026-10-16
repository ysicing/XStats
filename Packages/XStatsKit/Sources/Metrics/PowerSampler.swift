// GPU frequency portions adapted from gentpan/OpenStats, Copyright (c) 2026 GiantAccel, LLC.
// Original portions: MIT, see LICENSES/OpenStats-MIT.txt.
// XStats modifications: Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import IOKit
import SMC

/// 功耗与 CPU / GPU 频率
public struct PowerReading: Sendable, Equatable {
  /// 整机功耗（SMC PSTR）
  public var system: Double?
  /// 电源适配器输入（SMC PDTR），使用电池时为 nil
  public var adapter: Double?
  /// 电池充放电功率（SMC PPBR）
  public var battery: Double?
  /// GPU 功耗（IOReport Energy Model，两次采样之间的平均值）
  public var gpu: Double?
  /// 各类核心在工作时的平均频率（MHz），键为 perflevel，0 为最高性能档
  public var clusterFrequency: [Int: Double] = [:]
  /// GPU 工作状态的驻留时间加权平均频率（MHz），空闲或不支持时为 nil
  public var gpuFrequency: Double?

  public init(
    system: Double? = nil, adapter: Double? = nil, battery: Double? = nil, gpu: Double? = nil,
    clusterFrequency: [Int: Double] = [:], gpuFrequency: Double? = nil
  ) {
    self.system = system
    self.adapter = adapter
    self.battery = battery
    self.gpu = gpu
    self.clusterFrequency = clusterFrequency
    self.gpuFrequency = gpuFrequency
  }

  /// 清除已无读取方的实时指标，同时保留其他独立请求的频率或功耗。
  public func retaining(system: Bool, gpu: Bool, cpuFrequency: Bool, gpuFrequency: Bool)
    -> PowerReading?
  {
    let reading = PowerReading(
      system: system ? self.system : nil, adapter: system ? adapter : nil,
      battery: system ? battery : nil, gpu: gpu ? self.gpu : nil,
      clusterFrequency: cpuFrequency ? clusterFrequency : [:],
      gpuFrequency: gpuFrequency ? self.gpuFrequency : nil)
    return reading.system != nil || reading.adapter != nil || reading.battery != nil
      || reading.gpu != nil
      || !reading.clusterFrequency.isEmpty || reading.gpuFrequency != nil ? reading : nil
  }

}

/// 功耗读 SMC，CPU 频率与 GPU 能耗读 IOReport，都不需要 root。
/// 注：新款芯片上 IOReport 的 CPU 能耗计数器（mJ）长时间不更新，因此不显示 CPU 功耗。
public final class PowerSampler: @unchecked Sendable {
  private let smc = try? SMCConnection()
  private var energy: Subscription?
  private var cpuStates: Subscription?
  private var gpuStates: Subscription?
  private var lastGPUStates: (date: Date, sample: CFDictionary)?
  private lazy var gpuFrequencyTable: [Double]? = Self.readGPUFrequencyTable()
  private var lastEnergy: (date: Date, sample: CFDictionary)?
  private var lastStates: (date: Date, sample: CFDictionary)?
  private lazy var frequencyTables: [[Double]] = Self.readFrequencyTables()

  public init() {}

  /// SMC 读数几乎没有开销；IOReport 每次采样约 5 毫秒 CPU，GPU 功耗与 CPU 频率只在界面需要时读
  public func sample(
    system includeSystem: Bool = true, gpu includeGPU: Bool = true,
    frequency includeFrequency: Bool = true, gpuFrequency includeGPUFrequency: Bool = false,
    now: Date = Date()
  ) -> PowerReading {
    var reading = PowerReading()
    // CPU 详情可能只请求频率；温度/功耗功能关闭时不能顺带读取 SMC 功耗。
    if includeSystem {
      reading.system = positive(smc?.double(SMCKey("PSTR")))
      reading.adapter = positive(smc?.double(SMCKey("PDTR")))
      reading.battery = smc?.double(SMCKey("PPBR")).flatMap {
        $0.isFinite && abs($0) >= 0.01 ? $0 : nil
      }
    }
    if includeGPU { reading.gpu = sampleGPU(now: now) }
    if includeFrequency { reading.clusterFrequency = sampleFrequencies(now: now) }
    if includeGPUFrequency { reading.gpuFrequency = sampleGPUFrequency(now: now) }
    return reading
  }

  /// 需求变化或暂停后重新建立基线，避免把关闭期间的计数算进实时读数。
  public func resetBaselines(gpu: Bool = true, cpuFrequency: Bool = true, gpuFrequency: Bool = true)
  {
    if gpu { lastEnergy = nil }
    if cpuFrequency { lastStates = nil }
    if gpuFrequency { lastGPUStates = nil }
  }

  private func positive(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value > 0.05, value < 1000 else { return nil }
    return value
  }

  // MARK: GPU

  private func sampleGPU(now: Date) -> Double? {
    if energy == nil { energy = Subscription(group: "Energy Model", subgroup: nil) }
    guard let energy, let current = energy.sample() else { return nil }
    defer { lastEnergy = (now, current) }
    // 间隔太短噪声大；太长（界面关闭过一段时间）的平均值没有意义
    guard let last = lastEnergy, (0.2...15).contains(now.timeIntervalSince(last.date)),
      let delta = IOReportCreateSamplesDelta(last.sample, current, nil)?.takeRetainedValue()
    else {
      return nil
    }
    let seconds = now.timeIntervalSince(last.date)
    for channel in Subscription.channels(in: delta) where Subscription.name(channel) == "GPU Energy"
    {
      let value = Double(IOReportSimpleGetIntegerValue(channel, 0))
      let joules = value * Self.joulesPerUnit(Subscription.unit(channel))
      return joules / seconds
    }
    return nil
  }

  private func sampleGPUFrequency(now: Date) -> Double? {
    guard let table = gpuFrequencyTable else { return nil }
    if gpuStates == nil {
      gpuStates = Subscription(group: "GPU Stats", subgroup: "GPU Performance States")
    }
    guard let current = gpuStates?.sample() else { return nil }
    defer { lastGPUStates = (now, current) }
    guard let last = lastGPUStates, (0.2...15).contains(now.timeIntervalSince(last.date)),
      let delta = IOReportCreateSamplesDelta(last.sample, current, nil)?.takeRetainedValue()
    else { return nil }
    for channel in Subscription.channels(in: delta) where Subscription.name(channel) == "GPUPH" {
      let states = (0..<IOReportStateGetCount(channel)).map { index in
        (
          name: IOReportStateGetNameForIndex(channel, index)?.takeUnretainedValue() as String?
            ?? "",
          residency: IOReportStateGetResidency(channel, index)
        )
      }
      return Self.gpuFrequency(states, table: table)
    }
    return nil
  }

  static func gpuFrequency(_ states: [(name: String, residency: Int64)], table: [Double]) -> Double?
  {
    var weighted = 0.0
    var active = 0.0
    for state in states {
      guard state.name.hasPrefix("P"), let index = Int(state.name.dropFirst()), index > 0,
        index < table.count, state.residency > 0, table[index].isFinite, table[index] > 0
      else { continue }
      weighted += table[index] * Double(state.residency)
      active += Double(state.residency)
    }
    return active > 0 ? weighted / active : nil
  }

  static func parseGPUFrequencyTable(_ data: Data) -> [Double]? {
    guard data.count >= 16, data.count % 8 == 0 else { return nil }
    let values = stride(from: 0, to: data.count, by: 8).map { offset in
      Double(
        UInt32(
          littleEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
          }))
    }
    guard values.first == 0, let top = values.max() else { return nil }
    let scale = top > 100_000_000 ? 1e-6 : top > 100_000 ? 1e-3 : 1
    let table = values.map { $0 * scale }
    guard (200...5000).contains(table.max() ?? 0), table.dropFirst().allSatisfy({ $0 > 0 }) else {
      return nil
    }
    return table
  }

  private static func readGPUFrequencyTable() -> [Double]? {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS
    else {
      return nil
    }
    defer { IOObjectRelease(iterator) }
    while case let entry = IOIteratorNext(iterator), entry != 0 {
      defer { IOObjectRelease(entry) }
      var name = [CChar](repeating: 0, count: 128)
      guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS,
        String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
          == "pmgr",
        let data = IORegistryEntryCreateCFProperty(
          entry, "voltage-states9" as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? Data
      else { continue }
      return parseGPUFrequencyTable(data)
    }
    return nil
  }

  static func joulesPerUnit(_ unit: String) -> Double {
    switch unit {
    case "nJ": 1e-9
    case "uJ", "µJ": 1e-6
    case "mJ": 1e-3
    default: 1
    }
  }

  // MARK: CPU 频率

  private func sampleFrequencies(now: Date) -> [Int: Double] {
    if cpuStates == nil {
      cpuStates = Subscription(group: "CPU Stats", subgroup: "CPU Complex Performance States")
    }
    guard let cpuStates, let current = cpuStates.sample() else { return [:] }
    defer { lastStates = (now, current) }
    guard let last = lastStates, now.timeIntervalSince(last.date) <= 15,
      let delta = IOReportCreateSamplesDelta(last.sample, current, nil)?.takeRetainedValue()
    else { return [:] }

    var complexes: [ComplexResidency] = []
    for channel in Subscription.channels(in: delta) {
      let name = Subscription.name(channel)
      guard let letter = Self.complexLetter(name) else { continue }
      var states: [(String, Int64)] = []
      for index in 0..<IOReportStateGetCount(channel) {
        let stateName =
          IOReportStateGetNameForIndex(channel, index)?.takeUnretainedValue() as String? ?? ""
        states.append((stateName, IOReportStateGetResidency(channel, index)))
      }
      complexes.append(ComplexResidency(letter: letter, states: states))
    }
    let levels = Sysctl.int("hw.nperflevels") ?? 1
    return Self.clusterFrequencies(complexes, tables: frequencyTables, perfLevels: levels)
  }

  struct ComplexResidency {
    let letter: Character
    let states: [(name: String, residency: Int64)]
  }

  /// “ECPU”“PCPU”“MCPU0” 这类核心组通道；“PCPM”“MCPM0_IDLE” 是电源管理通道，不计入
  static func complexLetter(_ name: String) -> Character? {
    guard name.count >= 4, let first = name.first, first.isUppercase,
      name.dropFirst().hasPrefix("CPU"), name.dropFirst(4).allSatisfy(\.isNumber)
    else { return nil }
    return first
  }

  /// 按工作状态（V{n}P{m}）的驻留时间加权平均频率。同一字母的核心组合并；
  /// 各组按频率表的最高频率从高到低对应 perflevel 0、1、2
  static func clusterFrequencies(
    _ complexes: [ComplexResidency], tables: [[Double]], perfLevels: Int
  ) -> [Int: Double] {
    var weighted: [Character: (sum: Double, time: Double, top: Double)] = [:]
    for complex in complexes {
      let active = complex.states.filter { $0.name.hasPrefix("V") && $0.name.contains("P") }
      guard let table = table(forStateCount: active.count, letter: complex.letter, in: tables)
      else { continue }
      var entry = weighted[complex.letter] ?? (0, 0, table.max() ?? 0)
      for (index, state) in active.enumerated() where index < table.count {
        entry.sum += table[index] * Double(state.residency)
        entry.time += Double(state.residency)
      }
      weighted[complex.letter] = entry
    }
    let ordered = weighted.sorted { $0.value.top > $1.value.top }
    guard ordered.count == perfLevels else { return [:] }
    var result: [Int: Double] = [:]
    for (level, item) in ordered.enumerated() where item.value.time > 0 {
      result[level] = item.value.sum / item.value.time
    }
    return result
  }

  /// 状态数与频率表项数一致的表；有多张时能效核（E）取最低、其他取最高
  static func table(forStateCount count: Int, letter: Character, in tables: [[Double]]) -> [Double]?
  {
    let candidates = tables.filter { $0.count == count }
    return letter == "E"
      ? candidates.min { ($0.max() ?? 0) < ($1.max() ?? 0) }
      : candidates.max { ($0.max() ?? 0) < ($1.max() ?? 0) }
  }

  /// pmgr 的 voltage-states*-sram 属性：每项 8 字节（频率、电压，小端 UInt32）。
  /// 旧芯片单位是 Hz，新芯片直接是 MHz；第一项为 0 的是 GPU 等其他模块的表
  static func parseFrequencyTable(_ data: Data) -> [Double]? {
    guard data.count >= 16, data.count % 8 == 0 else { return nil }
    let values = stride(from: 0, to: data.count, by: 8).map { offset -> Double in
      let raw = data.subdata(in: offset..<offset + 4).withUnsafeBytes {
        $0.loadUnaligned(as: UInt32.self)
      }
      return Double(UInt32(littleEndian: raw))
    }
    guard let first = values.first, first > 0, let top = values.max() else { return nil }
    let scale = top > 100_000_000 ? 1e-6 : top > 100_000 ? 1e-3 : 1
    let megahertz = values.map { $0 * scale }
    // 合理的 CPU 频率范围
    guard (200...10_000).contains(megahertz.max() ?? 0) else { return nil }
    return megahertz
  }

  private static func readFrequencyTables() -> [[Double]] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS
    else {
      return []
    }
    defer { IOObjectRelease(iterator) }
    var tables: [[Double]] = []
    while case let entry = IOIteratorNext(iterator), entry != 0 {
      defer { IOObjectRelease(entry) }
      var name = [CChar](repeating: 0, count: 128)
      guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS,
        String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
          == "pmgr"
      else { continue }
      var properties: Unmanaged<CFMutableDictionary>?
      guard
        IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0)
          == KERN_SUCCESS,
        let dictionary = properties?.takeRetainedValue() as? [String: Any]
      else { continue }
      for (key, value) in dictionary where key.hasPrefix("voltage-states") && key.hasSuffix("-sram")
      {
        if let data = value as? Data, let table = parseFrequencyTable(data), !tables.contains(table)
        {
          tables.append(table)
        }
      }
    }
    return tables
  }
}

/// IOReport 订阅：只订阅需要的分组，减少每次采样的开销
private final class Subscription {
  private let channels: CFMutableDictionary
  private let subscription: IOReportSubscriptionRef

  init?(group: String, subgroup: String?) {
    guard
      let channels = IOReportCopyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0)?
        .takeRetainedValue()
    else {
      return nil
    }
    var subscribed: Unmanaged<CFMutableDictionary>?
    guard let subscription = IOReportCreateSubscription(nil, channels, &subscribed, 0, nil) else {
      return nil
    }
    subscribed?.release()
    self.channels = channels
    self.subscription = subscription
  }

  // subscription 是 OpaquePointer，不受 ARC 管理，本类也不释放它：IOReport 是私有框架，
  // 没有公开的释放入口，而它是否为 CF 对象无法验证——释放错了会在 dealloc 时崩溃。
  // 目前全进程只有 MetricsHub 持有的那一个 PowerSampler，三个 Subscription 各只创建一次且
  // 随进程存在，不会增长。若将来 PowerSampler 改成可反复创建，必须先确认正确的释放方式再补 deinit。

  func sample() -> CFDictionary? {
    IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue()
  }

  static func channels(in sample: CFDictionary) -> [CFDictionary] {
    let key = "IOReportChannels" as CFString
    guard let raw = CFDictionaryGetValue(sample, Unmanaged.passUnretained(key).toOpaque()) else {
      return []
    }
    let array = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
    return (0..<CFArrayGetCount(array)).map {
      Unmanaged<CFDictionary>.fromOpaque(CFArrayGetValueAtIndex(array, $0)).takeUnretainedValue()
    }
  }

  static func name(_ channel: CFDictionary) -> String {
    IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String? ?? ""
  }

  static func unit(_ channel: CFDictionary) -> String {
    (IOReportChannelGetUnitLabel(channel)?.takeUnretainedValue() as String? ?? "")
      .trimmingCharacters(in: .whitespaces)
  }
}
