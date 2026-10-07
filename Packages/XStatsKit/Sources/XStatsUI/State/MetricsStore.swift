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
    public private(set) var battery: BatteryStatus?
    public private(set) var processes: [ProcessUsage] = []
    /// 按应用汇总的磁盘读写排行，分数是最近十几秒的平均速率
    private(set) var diskRanking = ActivityRanking()
    public private(set) var systemCounts: SystemCounts?
    public private(set) var sensors: SensorReadings?
    /// 独立观察硬件能力，避免每次传感器采样都触发菜单栏布局重建。
    public private(set) var fanCount: Int?
    var supportsFans: Bool { (fanCount ?? 0) > 0 }
    public private(set) var power: PowerReading?
    public private(set) var powerHistory = History<Double>(capacity: historyCapacity)
    public private(set) var diskActivity: DiskActivity?
    public private(set) var diskReadHistory = History<Double>(capacity: historyCapacity)
    public private(set) var diskWriteHistory = History<Double>(capacity: historyCapacity)
    public private(set) var diskHealth: DiskHealth?
    public private(set) var lastUpdate: Date?

    public init(readBattery: Bool = true) { battery = readBattery ? BatterySampler.sample() : nil }

    /// 关闭功能后移除实时缓存，避免重新打开页面把旧值当作当前值。
    /// 持久化历史由 HistoryRecorder 管理，不在这里删除。
    func clearDisabledModules(_ enabled: Set<MonitoringModule>) {
        if !enabled.contains(.cpu), cpu != nil || !cpuTotal.elements.isEmpty {
            cpu = nil
            cpuTotal = History(capacity: Self.historyCapacity)
            cpuTimeline = History(capacity: Self.timelineCapacity)
            coreHistory = History(capacity: Self.historyCapacity)
        }
        if !enabled.contains(.memory), memory != nil || !memoryHistory.elements.isEmpty {
            memory = nil
            memoryHistory = History(capacity: Self.historyCapacity)
            pressureHistory = History(capacity: Self.historyCapacity)
            swapRate = nil; lastSwap = nil
        }
        if !enabled.contains(.network), network != nil || networkInterface != nil || !downloadHistory.elements.isEmpty {
            network = nil; networkInterface = nil
            downloadHistory = History(capacity: Self.historyCapacity)
            uploadHistory = History(capacity: Self.historyCapacity)
        }
        if !enabled.contains(.gpu), gpu != nil || !gpuHistory.elements.isEmpty {
            gpu = nil
            gpuHistory = History(capacity: Self.historyCapacity)
        }
        if !enabled.contains(.disk), disk != nil || diskActivity != nil || diskHealth != nil || !diskReadHistory.elements.isEmpty {
            disk = nil; diskActivity = nil; diskHealth = nil
            diskReadHistory = History(capacity: Self.historyCapacity)
            diskWriteHistory = History(capacity: Self.historyCapacity)
        }
        if !enabled.contains(.battery), battery != nil { battery = nil }
        if !enabled.contains(.thermal), sensors != nil || power?.system != nil || power?.gpu != nil || power?.battery != nil || power?.adapter != nil
            || !powerHistory.elements.isEmpty {
            sensors = nil
            power = enabled.contains(.cpu) && power?.clusterFrequency.isEmpty == false
                ? PowerReading(clusterFrequency: power?.clusterFrequency ?? [:]) : nil
            powerHistory = History(capacity: Self.historyCapacity)
        }
        if !enabled.contains(.cpu), power?.clusterFrequency.isEmpty == false { power?.clusterFrequency = [:] }
    }

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
            // 排行只需要磁盘计数，不必构建带名称、文案和其他指标的完整界面行。
            // 同组有读取计数时才采用写入合计，保留混合权限进程和缺失计数的既有语义，
            // 并分别累加读写以保持浮点运算顺序。
            var totals: [String: (read: Double?, write: Double)] = [:]
            for process in processes {
                let id = process.rowGroupID
                var total = totals[id] ?? (nil, 0)
                if let read = process.diskRead { total.read = (total.read ?? 0) + read }
                total.write += process.diskWrite ?? 0
                totals[id] = total
            }
            let activity = totals.mapValues { total in total.read.map { $0 + total.write } ?? 0 }
            diskRanking.update(activity)
        }
        if let counts = snapshot.systemCounts { systemCounts = counts }
        if let sensors = snapshot.sensors { mergeSensors(sensors) }
    }

    /// 不同页面采集的温度分组不同，按组合并，避免切页时数据闪烁
    private func mergeSensors(_ new: SensorReadings) {
        if let count = new.fanCount, count != fanCount { fanCount = count }
        guard let old = sensors else {
            sensors = new
            return
        }
        var byGroup = Dictionary(uniqueKeysWithValues: old.temperatures.map { ($0.group, $0) })
        for summary in new.temperatures { byGroup[summary.group] = summary }
        let ordered = TemperatureGroup.allCases.compactMap { byGroup[$0] }
        // 读取失败时沿用的旧风扇数据不再推进起步窗口，去掉“启动中”以免提示超出时限。
        let fans = new.fans.isEmpty ? old.fans.map { fan in
            var fan = fan
            fan.isStarting = false
            return fan
        } : new.fans
        sensors = SensorReadings(temperatures: ordered, fans: fanCount == 0 ? [] : fans, fanCount: fanCount)
    }

    var fastestFan: FanState? {
        sensors?.fans.max { $0.current < $1.current }
    }
}
