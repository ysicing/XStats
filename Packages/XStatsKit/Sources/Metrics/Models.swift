// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Darwin
import Foundation
import Localization
import SMC

public struct CPUCluster: Sendable, Equatable, Identifiable {
  /// 保留系统报告的核心类型，界面说明不依赖本地化名称或机型猜测。
  public enum Kind: Sendable {
    case superCore, performance, efficiency, unknown

    init(systemName: String) {
      switch systemName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "super": self = .superCore
      case "performance": self = .performance
      case "efficiency": self = .efficiency
      default: self = .unknown
      }
    }
  }

  public let id: Int  // perflevel 序号，0 为最高性能档
  public let name: String  // 超级核 / 性能核 / 能效核
  public let coreIndices: [Int]  // 对应 host_processor_info 的核心序号
  public let kind: Kind

  init(id: Int, name: String, coreIndices: [Int], kind: Kind = .unknown) {
    self.id = id
    self.name = name
    self.coreIndices = coreIndices
    self.kind = kind
  }
}

public struct CPUTopology: Sendable, Equatable {
  public let brand: String
  public let logicalCores: Int
  public let clusters: [CPUCluster]
}

public struct CPULoad: Sendable, Equatable {
  public var total: Double
  public var user: Double
  public var system: Double
  public var perCore: [Double]
  public var loadAverage: [Double]
  /// macOS 系统热状态，与传感器温度独立；没有采样时不假定为正常。
  public var thermalState: ProcessInfo.ThermalState? = nil
}

public enum MemoryPressure: Int, Sendable {
  case normal = 1
  case warning = 2
  case critical = 4

  public var title: String {
    switch self {
    case .normal: tr("正常")
    case .warning: tr("偏高")
    case .critical: tr("严重")
    }
  }
}

public struct MemoryUsage: Sendable, Equatable {
  public var total: UInt64
  public var app: UInt64
  public var wired: UInt64
  public var compressed: UInt64
  public var cached: UInt64
  public var swapUsed: UInt64
  public var swapTotal: UInt64
  public var pressure: MemoryPressure
  /// 被压缩的内容原本的大小；与 compressed 之差就是压缩省下的内存
  public var uncompressed: UInt64
  /// 开机以来从交换区换入 / 换出的累计字节数，用相邻两次采样算速率
  public var swapInBytes: UInt64
  public var swapOutBytes: UInt64

  public var used: UInt64 { app + wired + compressed }
  public var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
  public var available: UInt64 { total > used ? total - used : 0 }
  /// 空闲 = 总量 - 已用 - 缓存文件
  public var free: UInt64 { total > used + cached ? total - used - cached : 0 }
  public var compressionSavings: UInt64 {
    uncompressed > compressed ? uncompressed - compressed : 0
  }
  public var compressionRatio: Double? {
    compressed > 0 && uncompressed > 0 ? Double(uncompressed) / Double(compressed) : nil
  }
}

public struct NetworkInterfaceInfo: Sendable, Equatable {
  public var bsdName: String
  public var displayName: String
  public var ipv4: String?
}

public struct NetworkRate: Sendable, Equatable {
  public var connection: NetworkIconState? = nil
  public var downloadBytesPerSecond: Double
  public var uploadBytesPerSecond: Double
  public var totalDownloaded: UInt64
  public var totalUploaded: UInt64
}

public struct DiskUsage: Sendable, Equatable {
  public var volumeName: String
  public var total: UInt64
  /// 可用空间，包含系统可随时清除的缓存，与访达显示一致
  public var available: UInt64
  /// 可用空间里可清除的那部分
  public var purgeable: UInt64
  /// APFS 启动容器组成；读取失败或非启动卷时为 nil。
  public var breakdown: DiskBreakdown?

  public init(volumeName: String, total: UInt64, available: UInt64, purgeable: UInt64 = 0) {
    self.volumeName = volumeName
    self.total = total
    self.available = available
    self.purgeable = min(purgeable, available)
  }

  public var used: UInt64 { total > available ? total - available : 0 }
  public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
  /// 不含可清除部分的真正空闲空间
  public var free: UInt64 { available - purgeable }
  public var purgeableFraction: Double { total == 0 ? 0 : Double(purgeable) / Double(total) }
  public var freeFraction: Double { total == 0 ? 0 : Double(free) / Double(total) }
}

public struct BatteryStatus: Sendable, Equatable {
  public var level: Double  // 0...1
  public var isCharging: Bool
  public var isPluggedIn: Bool
  public var isFullyCharged: Bool
  public var minutesRemaining: Int?  // 放电剩余或充满所需时间
  public var cycleCount: Int?
  public var health: Double?  // 0...1
  public var adapterWatts: Int?
  public var designCapacity: Int?  // mAh
  public var fullChargeCapacity: Int?  // mAh
  public var voltage: Double?  // V
  public var amperage: Double?  // A，放电为负
}

public struct GPUUsage: Sendable, Equatable {
  public var name: String
  public var utilization: Double  // 0...1
  public var coreCount: Int?
  public var rendererUtilization: Double?
  public var tilerUtilization: Double?
  public var memoryInUse: UInt64?
}

public struct ProcessUsage: Sendable, Equatable, Identifiable {
  public var id: Int32 { pid }
  public let pid: Int32
  public let name: String
  public let executablePath: String?
  public let appBundlePath: String?
  public var cpu: Double  // 以单核为 100%，与活动监视器一致
  public var memory: UInt64  // 自己的进程为 phys_footprint；其他用户的进程为常驻内存
  public var uid: UInt32 = 0
  public var userName: String = ""
  /// 累计 CPU 时间（秒）
  public var cpuTime: Double = 0
  /// 以下只有当前用户自己的进程能读到
  public var threads: Int?
  public var idleWakeups: Double?  // 每秒
  public var diskRead: Double?  // 字节 / 秒
  public var diskWrite: Double?
  /// 是否属于当前用户：可以读取详细数据，也可以结束
  public var isOwned: Bool = true

  public init(
    pid: Int32, name: String, executablePath: String?, appBundlePath: String?, cpu: Double,
    memory: UInt64
  ) {
    self.pid = pid
    self.name = name
    self.executablePath = executablePath
    self.appBundlePath = appBundlePath
    self.cpu = cpu
    self.memory = memory
  }
}

/// 全系统的进程数与线程数（包括无权读取详情的系统进程）
public struct SystemCounts: Sendable, Equatable {
  public var processes: Int
  public var threads: Int

  public static func read() -> SystemCounts? {
    // mach_host_self() 与 processor_set_default 都返回需要调用方释放的 send right；
    // 每个采样周期都会调用，不释放会让端口引用计数持续增长
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var set: processor_set_name_t = 0
    guard processor_set_default(host, &set) == KERN_SUCCESS else { return nil }
    defer { mach_port_deallocate(mach_task_self_, set) }
    var load = processor_set_load_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<processor_set_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &load) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        processor_set_statistics(set, PROCESSOR_SET_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return SystemCounts(processes: Int(load.task_count), threads: Int(load.thread_count))
  }
}

public struct TemperatureSummary: Sendable, Equatable, Identifiable {
  public var id: TemperatureGroup { group }
  public let group: TemperatureGroup
  public var average: Double
  public var maximum: Double
  public var sensorCount: Int
}

public struct SensorReadings: Sendable, Equatable {
  public var temperatures: [TemperatureSummary]
  public var fans: [FanState]
  /// nil 表示数量读取失败或未知，0 才表示确认无风扇。
  public var fanCount: Int?

  public init(temperatures: [TemperatureSummary], fans: [FanState], fanCount: Int? = nil) {
    self.temperatures = temperatures
    self.fans = fans
    self.fanCount = fanCount
  }

  public func temperature(_ group: TemperatureGroup) -> TemperatureSummary? {
    temperatures.first { $0.group == group }
  }
}

public struct SystemInfo: Sendable, Equatable {
  public var modelName: String
  public var osVersion: String
  public var bootDate: Date?
  /// 例如 “Mac17,6”
  public var modelIdentifier: String = ""
  /// 系统版号，例如 “26A428”
  public var osBuild: String = ""
  public var serialNumber: String?
  /// 启动时读取的图形硬件信息，独立于 GPU 实时占用采样。
  public var gpuName: String?
  public var gpuCoreCount: Int?
}

public struct MetricsSnapshot: Sendable {
  /// 暂停期间只供风扇与合盖保护使用，不写入普通监控历史或更新界面。
  public var isSafetySample = false
  public var date = Date()
  /// Hub 的采样代次；手工快照与演示数据不设置。用于拒绝开关变化前已排队的结果。
  public var samplingGeneration: Int?
  public var cpu: CPULoad?
  /// 系统热压力也随温度需求采集，不依赖 CPU 使用率采样。
  public var thermalState: ProcessInfo.ThermalState?
  public var memory: MemoryUsage?
  public var network: NetworkRate?
  public var networkInterface: NetworkInterfaceInfo?
  public var disk: DiskUsage?
  public var battery: BatteryStatus?
  public var gpu: GPUUsage?
  public var processes: [ProcessUsage]?
  public var appEnergy: AppEnergyReading?
  public var systemCounts: SystemCounts?
  public var sensors: SensorReadings?
  public var power: PowerReading?
  public var diskActivity: DiskActivity?
  public var diskHealth: DiskHealth?

  public init() {}
}
