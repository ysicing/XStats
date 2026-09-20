import Foundation
import Metrics
import Observation
import SMC

/// 一次采样的时间与数值
public struct TimedValue: Sendable, Equatable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// 主线程上的最新指标与短历史，只保留界面需要的数据
@MainActor
@Observable
public final class MetricsStore {
    public static let historyCapacity = 60

    public let topology = CPUSampler.topology()
    public private(set) var system = SystemInfoReader.read()

    public private(set) var cpu: CPULoad?
    public private(set) var cpuTotal = History<Double>(capacity: historyCapacity)
    /// 带时间戳的 CPU 总占用，供可选 1 / 3 / 5 分钟的走势图按时间定位；每秒一次时正好装下 5 分钟
    public private(set) var cpuTimeline = History<TimedValue>(capacity: timelineCapacity)
    public static let timelineCapacity = 300
    /// 每次采样各核心的占用，用于核心热力图
    public private(set) var coreHistory = History<[Double]>(capacity: historyCapacity)

    public private(set) var memory: MemoryUsage?
    public private(set) var memoryHistory = History<Double>(capacity: historyCapacity)
    public private(set) var pressureHistory = History<MemoryPressure>(capacity: historyCapacity)
    /// 交换区换入 / 换出速率（字节 / 秒）
    public private(set) var swapRate: (swapIn: Double, swapOut: Double)?
    @ObservationIgnored private var lastSwap: (date: Date, swapIn: UInt64, swapOut: UInt64)?
    public private(set) var network: NetworkRate?
    public private(set) var downloadHistory = History<Double>(capacity: historyCapacity)
    public private(set) var uploadHistory = History<Double>(capacity: historyCapacity)
    public private(set) var networkInterface: NetworkInterfaceInfo?

    public private(set) var gpu: GPUUsage?
    public private(set) var gpuHistory = History<Double>(capacity: historyCapacity)
    public private(set) var disk: DiskUsage?
    /// 启动时读取一次，确保面板首次打开时布局（是否有电池卡片）就已确定
    public private(set) var battery: BatteryStatus? = BatterySampler.sample()
    public private(set) var processes: [ProcessUsage] = []
    /// 按应用汇总的磁盘读写排行，分数是最近十几秒的平均速率
    private(set) var diskRanking = ActivityRanking()
    public private(set) var systemCounts: SystemCounts?
    public private(set) var sensors: SensorReadings?
    public private(set) var power: PowerReading?
    public private(set) var powerHistory = History<Double>(capacity: historyCapacity)
    public private(set) var diskActivity: DiskActivity?
    public private(set) var diskReadHistory = History<Double>(capacity: historyCapacity)
    public private(set) var diskWriteHistory = History<Double>(capacity: historyCapacity)
    public private(set) var diskHealth: DiskHealth?
    public private(set) var lastUpdate: Date?

    public init() {}

    public func apply(_ snapshot: MetricsSnapshot) {
        lastUpdate = snapshot.date
        if let activity = snapshot.diskActivity {
            diskActivity = activity
            diskReadHistory.append(activity.readRate)
            diskWriteHistory.append(activity.writeRate)
        }
        if let health = snapshot.diskHealth { diskHealth = health }
        if let power = snapshot.power {
            self.power = power
            if let system = power.system { powerHistory.append(system) }
        }
        if let cpu = snapshot.cpu {
            self.cpu = cpu
            cpuTotal.append(cpu.total)
            cpuTimeline.append(TimedValue(date: snapshot.date, value: cpu.total))
            coreHistory.append(cpu.perCore)
        }
        if let memory = snapshot.memory {
            self.memory = memory
            memoryHistory.append(memory.usedFraction)
            pressureHistory.append(memory.pressure)
            if let last = lastSwap, snapshot.date > last.date {
                let seconds = snapshot.date.timeIntervalSince(last.date)
                swapRate = (Double(memory.swapInBytes >= last.swapIn ? memory.swapInBytes - last.swapIn : 0) / seconds,
                            Double(memory.swapOutBytes >= last.swapOut ? memory.swapOutBytes - last.swapOut : 0) / seconds)
            }
            lastSwap = (snapshot.date, memory.swapInBytes, memory.swapOutBytes)
        }
        if let network = snapshot.network {
            self.network = network
            downloadHistory.append(network.downloadBytesPerSecond)
            uploadHistory.append(network.uploadBytesPerSecond)
        }
        if let interface = snapshot.networkInterface { networkInterface = interface }
        if let gpu = snapshot.gpu {
            self.gpu = gpu
            gpuHistory.append(gpu.utilization)
        }
        if let disk = snapshot.disk { self.disk = disk }
        if let battery = snapshot.battery { self.battery = battery }
        if let processes = snapshot.processes {
            self.processes = processes
            var activity: [String: Double] = [:]
            for row in ProcessRowModel.grouped(processes) {
                activity[row.id] = row.disk.map { $0.read + $0.write } ?? 0
            }
            diskRanking.update(activity)
        }
        if let counts = snapshot.systemCounts { systemCounts = counts }
        if let sensors = snapshot.sensors { mergeSensors(sensors) }
    }

    /// 不同页面采集的温度分组不同，按组合并，避免切页时数据闪烁
    private func mergeSensors(_ new: SensorReadings) {
        guard let old = sensors else {
            sensors = new
            return
        }
        var byGroup = Dictionary(uniqueKeysWithValues: old.temperatures.map { ($0.group, $0) })
        for summary in new.temperatures { byGroup[summary.group] = summary }
        let ordered = TemperatureGroup.allCases.compactMap { byGroup[$0] }
        sensors = SensorReadings(temperatures: ordered, fans: new.fans.isEmpty ? old.fans : new.fans)
    }

    var fastestFan: FanState? {
        sensors?.fans.max { $0.current < $1.current }
    }
}
