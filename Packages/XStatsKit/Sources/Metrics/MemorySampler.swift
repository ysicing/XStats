import Darwin
import Foundation

public struct MemorySampler {
    private let total = ProcessInfo.processInfo.physicalMemory
    private let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size)
    }()

    public init() {}

    public func sample() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        // 与“活动监视器”口径一致：App 内存 = internal - purgeable
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        let swapUsed = hasSwap ? swap.xsu_used : 0
        let swapTotal = hasSwap ? swap.xsu_total : 0

        let level = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        return MemoryUsage(total: total,
                           app: app,
                           wired: UInt64(stats.wire_count) * pageSize,
                           compressed: UInt64(stats.compressor_page_count) * pageSize,
                           cached: (UInt64(stats.external_page_count) + purgeable) * pageSize,
                           swapUsed: swapUsed,
                           swapTotal: swapTotal,
                           pressure: MemoryPressure(rawValue: level) ?? .normal,
                           uncompressed: stats.total_uncompressed_pages_in_compressor * pageSize,
                           swapInBytes: stats.swapins * pageSize,
                           swapOutBytes: stats.swapouts * pageSize)
    }
}
