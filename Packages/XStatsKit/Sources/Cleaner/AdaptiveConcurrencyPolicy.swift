// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

/// 按需任务可复用的并发决策；每次操作持有独立值，不创建任务、计时器或监控。
public struct AdaptiveConcurrencyPolicy: Sendable {
  public struct Load: Sendable {
    public enum MemoryPressure: Int, Sendable {
      case normal = 1
      case warning = 2
      case critical = 4
    }

    public let cpuUsage: Double?
    public let memoryPressure: MemoryPressure?
    public let thermalState: ProcessInfo.ThermalState

    /// CPU 使用率为 0...1；调用方只应传入新鲜样本，缺失时传 nil。
    public init(
      cpuUsage: Double?, memoryPressure: MemoryPressure?,
      thermalState: ProcessInfo.ThermalState = .nominal
    ) {
      self.cpuUsage = cpuUsage
      self.memoryPressure = memoryPressure
      self.thermalState = thermalState
    }

    /// 复用调用方的 CPU 样本，只按需读取内存压力与温度状态，不启动采样器。
    public static func current(cpuUsage: Double? = nil) -> Self {
      var pressure: Int32 = 0
      var size = MemoryLayout<Int32>.size
      let status = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
      return Self(
        cpuUsage: cpuUsage,
        memoryPressure: status == 0 ? MemoryPressure(rawValue: Int(pressure)) : nil,
        thermalState: ProcessInfo.processInfo.thermalState)
    }
  }

  public let maximum: Int
  public private(set) var limit = 2
  private var headroomSince: TimeInterval?

  public init(activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
    maximum = max(2, activeProcessorCount / 2)
  }

  /// 返回可派发的新任务总并发上限；0 表示压力严重，应暂停派发并保留取消能力。
  /// now 使用单调时间（秒）；调用方管理采样频率及已运行任务，不应强制中止它们。
  @discardableResult
  public mutating func update(
    load: Load, now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Int {
    if load.memoryPressure == .critical || load.thermalState == .critical {
      limit = 0
      headroomSince = nil
      return limit
    }
    guard let cpu = load.cpuUsage, cpu.isFinite, (0...1).contains(cpu),
      load.memoryPressure == .normal, load.thermalState == .nominal
    else {
      limit = 2
      headroomSince = nil
      return limit
    }
    limit = max(2, limit)
    if cpu >= 0.85 {
      limit = 2
      headroomSince = nil
    } else if cpu <= 0.55 {
      if let since = headroomSince, now - since >= 3 {
        limit = min(maximum, limit + 1)
        headroomSince = now
      } else if headroomSince == nil {
        headroomSince = now
      }
    } else {
      headroomSince = nil
    }
    return limit
  }
}
