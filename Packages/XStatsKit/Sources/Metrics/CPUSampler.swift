import Darwin
import Foundation
import Localization

public struct CPUSampler {
    private var previousTicks: [[UInt32]] = []

    public init() {}

    public static func topology() -> CPUTopology {
        let brand = Sysctl.string("machdep.cpu.brand_string") ?? "CPU"
        let logical = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let levels = Sysctl.int("hw.nperflevels") ?? 1

        guard levels > 1 else {
            return CPUTopology(brand: brand, logicalCores: logical,
                               clusters: [CPUCluster(id: 0, name: tr("核心"), coreIndices: Array(0..<logical))])
        }

        // 核心序号从最低性能档开始排列：perflevel(n-1) 在前，perflevel0 在后
        var clusters: [CPUCluster] = []
        var offset = 0
        for level in stride(from: levels - 1, through: 0, by: -1) {
            let count = Sysctl.int("hw.perflevel\(level).logicalcpu") ?? 0
            guard count > 0 else { continue }
            let raw = Sysctl.string("hw.perflevel\(level).name") ?? ""
            clusters.append(CPUCluster(id: level, name: localizedClusterName(raw), coreIndices: Array(offset..<offset + count)))
            offset += count
        }
        return CPUTopology(brand: brand, logicalCores: logical, clusters: clusters.sorted { $0.id < $1.id })
    }

    private static func localizedClusterName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "super": tr("超级核")
        case "performance": tr("性能核")
        case "efficiency": tr("能效核")
        default: raw.isEmpty ? tr("核心") : raw
        }
    }

    public mutating func sample() -> CPULoad? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        // 内核分配的数组必须归还，否则每次采样都会泄漏
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        ticks.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            ticks.append((0..<states).map { UInt32(bitPattern: info[core * states + $0]) })
        }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return nil }

        var perCore: [Double] = []
        perCore.reserveCapacity(ticks.count)
        var sumUser: UInt64 = 0, sumSystem: UInt64 = 0, sumAll: UInt64 = 0
        for (now, before) in zip(ticks, previousTicks) {
            let delta = zip(now, before).map { UInt64($0 &- $1) }
            let user = delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]
            let system = delta[Int(CPU_STATE_SYSTEM)]
            let all = user + system + delta[Int(CPU_STATE_IDLE)]
            perCore.append(all == 0 ? 0 : Double(user + system) / Double(all))
            sumUser += user
            sumSystem += system
            sumAll += all
        }
        guard sumAll > 0 else { return nil }

        var averages = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&averages, 3)
        let user = Double(sumUser) / Double(sumAll)
        let system = Double(sumSystem) / Double(sumAll)
        return CPULoad(total: min(1, user + system), user: user, system: system, perCore: perCore,
                       loadAverage: loadCount > 0 ? Array(averages.prefix(Int(loadCount))) : [])
    }
}
