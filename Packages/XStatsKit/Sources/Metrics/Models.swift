import Darwin
import Foundation
import Localization
import SMC

public struct CPUCluster: Sendable, Equatable, Identifiable {
    public let id: Int              // perflevel 序号，0 为最高性能档
    public let name: String         // 超级核 / 性能核 / 能效核
    public let coreIndices: [Int]   // 对应 host_processor_info 的核心序号
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
}

public enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

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
    public var compressionSavings: UInt64 { uncompressed > compressed ? uncompressed - compressed : 0 }
    public var compressionRatio: Double? { compressed > 0 && uncompressed > 0 ? Double(uncompressed) / Double(compressed) : nil }
}

public struct NetworkInterfaceInfo: Sendable, Equatable {
    public var bsdName: String
    public var displayName: String
    public var ipv4: String?
}

public struct NetworkRate: Sendable, Equatable {
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
    public var level: Double            // 0...1
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFullyCharged: Bool
    public var minutesRemaining: Int?   // 放电剩余或充满所需时间
    public var cycleCount: Int?
    public var health: Double?          // 0...1
    public var adapterWatts: Int?
}

public struct GPUUsage: Sendable, Equatable {
    public var name: String
    public var utilization: Double      // 0...1
    public var coreCount: Int?
}

public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let executablePath: String?
    public let appBundlePath: String?
    public var cpu: Double              // 以单核为 100%，与活动监视器一致
    public var memory: UInt64           // 自己的进程为 phys_footprint；其他用户的进程为常驻内存
    public var uid: UInt32 = 0
    public var userName: String = ""
    /// 累计 CPU 时间（秒）
    public var cpuTime: Double = 0
    /// 以下只有当前用户自己的进程能读到
    public var threads: Int?
    public var idleWakeups: Double?     // 每秒
    public var diskRead: Double?        // 字节 / 秒
    public var diskWrite: Double?
    /// 是否属于当前用户：可以读取详细数据，也可以结束
    public var isOwned: Bool = true

    public init(pid: Int32, name: String, executablePath: String?, appBundlePath: String?, cpu: Double, memory: UInt64) {
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
        var set: processor_set_name_t = 0
        guard processor_set_default(mach_host_self(), &set) == KERN_SUCCESS else { return nil }
        var load = processor_set_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<processor_set_load_info>.size / MemoryLayout<integer_t>.size)
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

    public init(temperatures: [TemperatureSummary], fans: [FanState]) {
        self.temperatures = temperatures
        self.fans = fans
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
}

public struct MetricsSnapshot: Sendable {
    public var date = Date()
    public var cpu: CPULoad?
    public var memory: MemoryUsage?
    public var network: NetworkRate?
    public var networkInterface: NetworkInterfaceInfo?
    public var disk: DiskUsage?
    public var battery: BatteryStatus?
    public var gpu: GPUUsage?
    public var processes: [ProcessUsage]?
    public var systemCounts: SystemCounts?
    public var sensors: SensorReadings?
    public var power: PowerReading?
    public var diskActivity: DiskActivity?
    public var diskHealth: DiskHealth?

    public init() {}
}
