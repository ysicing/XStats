import Foundation
import SMC

/// 描述当前界面需要哪些指标。面板关闭时只采菜单栏用到的项目。
public struct MetricsDemand: Sendable, Equatable {
    public var interval: Duration = .seconds(2)
    /// 所有者单调递增的代次；快速开关最终需求相同时仍须取消已排队的旧快照。
    public var generation: Int = 0
    public var cpu = false
    public var memory = false
    public var network = false
    public var gpu = false
    public var disk = false
    public var battery = false
    public var processes = false
    /// 进程管理器打开时：连同其他用户与系统的进程一起采集
    public var systemProcesses = false
    public var temperatures: Set<TemperatureGroup> = []
    public var fans = false
    /// 整机功耗与 GPU 功耗
    public var power = false
    /// 各类核心的频率
    public var cpuFrequency = false
    /// 磁盘读写速率与 SMART 健康信息
    public var diskDetail = false

    public init() {}

    /// 没有读取方时连采样循环也停止，不能只跳过某几个采集器后继续定时唤醒。
    public var hasSamples: Bool {
        cpu || memory || network || gpu || disk || battery || processes || systemProcesses
            || !temperatures.isEmpty || fans || power || cpuFrequency || diskDetail
    }
}

public actor MetricsHub {
    private var cpu = CPUSampler()
    private let memory = MemorySampler()
    private var network = NetworkSampler()
    private var processes = ProcessSampler()
    private let sensors = SensorSampler()
    private let power = PowerSampler()
    private var diskActivity = DiskActivitySampler()

    private var demand = MetricsDemand()
    private var handler: (@MainActor @Sendable (MetricsSnapshot) -> Void)?
    private var loop: Task<Void, Never>?
    private var paused = false
    /// 启动后第一次采集全部指标，面板首次打开时各页面已有数据，高度一次测准
    private var primed = false

    private var lastDisk = Date.distantPast
    private var lastBattery = Date.distantPast
    private var lastInterface = Date.distantPast
    private var lastPower = Date.distantPast
    private var lastDiskHealth = Date.distantPast

    public init() {}

    /// 正常启动预采全部指标以稳定首次布局；专用快照和资源验证可仅采当前需求。
    public func start(primeAllMetrics: Bool = true,
                      handler: @escaping @MainActor @Sendable (MetricsSnapshot) -> Void) {
        if !primeAllMetrics { primed = true }
        self.handler = handler
        restart()
    }

    public func update(_ newDemand: MetricsDemand) {
        // actor 请求不保证 FIFO，晚到的旧开关需求不能重启已关闭的采样。
        guard newDemand.generation >= demand.generation else { return }
        guard newDemand != demand else { return }
        let needsImmediateRefresh = newDemand.interval < demand.interval
            || (newDemand.cpu && !demand.cpu)
            || (newDemand.memory && !demand.memory)
            || (newDemand.network && !demand.network)
            || (newDemand.gpu && !demand.gpu)
            || (newDemand.battery && !demand.battery)
            || !newDemand.temperatures.isSubset(of: demand.temperatures)
            || (newDemand.fans && !demand.fans)
            || (newDemand.processes && !demand.processes)
            || (newDemand.disk && !demand.disk)
            || (newDemand.diskDetail && !demand.diskDetail)
        if (newDemand.power && !demand.power) || (newDemand.cpuFrequency && !demand.cpuFrequency) {
            lastPower = .distantPast
        }
        // 关闭期间的累计计数不属于重新启用后的实时速率。
        if newDemand.cpu && !demand.cpu { cpu = CPUSampler() }
        if newDemand.network && !demand.network { network = NetworkSampler() }
        if newDemand.diskDetail && !demand.diskDetail { diskActivity = DiskActivitySampler() }
        demand = newDemand
        if needsImmediateRefresh {
            lastDisk = .distantPast
            lastBattery = .distantPast
            lastInterface = .distantPast
            lastDiskHealth = .distantPast
        }

        restart()
    }

    /// 锁屏、屏幕休眠或系统睡眠时暂停采样
    public func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        restart()
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        handler = nil
    }

    private static func everything(interval: Duration) -> MetricsDemand {
        var demand = MetricsDemand()
        demand.interval = interval
        demand.cpu = true
        demand.memory = true
        demand.network = true
        demand.gpu = true
        demand.disk = true
        demand.battery = true
        demand.processes = true
        demand.temperatures = Set(TemperatureGroup.allCases)
        demand.fans = true
        demand.power = true
        demand.cpuFrequency = true
        demand.diskDetail = true
        return demand
    }

    private func restart() {
        loop?.cancel()
        guard !paused, handler != nil, demand.hasSamples else {
            loop = nil
            return
        }
        loop = Task { await self.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            let snapshot = collect()
            if let handler {
                await MainActor.run {
                    // 等待主线程期间需求可能已关闭；取消的旧轮次不能发布快照。
                    if !Task.isCancelled { handler(snapshot) }
                }
            }
            // 容差让系统合并定时器唤醒，降低功耗
            try? await Task.sleep(for: demand.interval, tolerance: demand.interval / 4)
        }
    }

    private func collect() -> MetricsSnapshot {
        let now = Date()
        var snapshot = MetricsSnapshot()
        snapshot.samplingGeneration = self.demand.generation
        let demand = primed ? self.demand : Self.everything(interval: self.demand.interval)
        primed = true
        if demand.cpu { snapshot.cpu = cpu.sample() }

        if demand.memory { snapshot.memory = memory.sample() }
        if demand.network {
            snapshot.network = network.sample()
            if now.timeIntervalSince(lastInterface) > 15 {
                snapshot.networkInterface = NetworkSampler.primaryInterface()
                lastInterface = now
            }
        }
        if demand.gpu { snapshot.gpu = GPUSampler.sample() }
        if demand.disk, now.timeIntervalSince(lastDisk) > 30 {
            snapshot.disk = DiskSampler.sample()
            lastDisk = now
        }
        if demand.battery, now.timeIntervalSince(lastBattery) > 10 {
            snapshot.battery = BatterySampler.sample()
            lastBattery = now
        }
        if demand.processes || demand.systemProcesses {
            snapshot.processes = processes.sample(includeSystem: demand.systemProcesses)
            snapshot.systemCounts = SystemCounts.read()
        }
        if !demand.temperatures.isEmpty || demand.fans {
            snapshot.sensors = sensors.sample(groups: demand.temperatures, includeFans: demand.fans)
        }
        if demand.diskDetail {
            snapshot.diskActivity = diskActivity.sample(now: now)
            if now.timeIntervalSince(lastDiskHealth) > 60 {
                snapshot.diskHealth = DiskHealthReader.read()
                lastDiskHealth = now
            }
        }
        // IOReport 采样有一定开销，至少间隔 2 秒
        if demand.power || demand.cpuFrequency, now.timeIntervalSince(lastPower) >= 1.9 {
            snapshot.power = power.sample(system: demand.power, gpu: demand.power, frequency: demand.cpuFrequency, now: now)
            lastPower = now
        }
        return snapshot
    }
}
