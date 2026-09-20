import Foundation
import IOKit
import IOKit.ps
import Localization

// MARK: - 磁盘

public enum DiskSampler {
    public static func sample(volume: URL = URL(fileURLWithPath: "/")) -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        // “重要用途可用空间”包含可清除空间，与访达显示一致；减去普通可用空间就是可清除的部分
        let available = max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)
        let strict = Int64(values.volumeAvailableCapacity ?? 0)
        return DiskUsage(volumeName: values.volumeLocalizedName ?? tr("磁盘"),
                         total: UInt64(total), available: UInt64(available),
                         purgeable: UInt64(max(0, available - strict)))
    }
}

// MARK: - 电池

public enum BatterySampler {
    public static func sample() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charged = description[kIOPSIsChargedKey] as? Bool ?? false
            let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (description[minutesKey] as? Int).flatMap { $0 > 0 ? $0 : nil }

            var status = BatteryStatus(level: maximum > 0 ? Double(current) / Double(maximum) : 0,
                                       isCharging: isCharging, isPluggedIn: pluggedIn, isFullyCharged: charged,
                                       minutesRemaining: pluggedIn && !isCharging ? nil : minutes)
            fillRegistryDetails(&status)
            return status
        }
        return nil
    }

    private static func fillRegistryDetails(_ status: inout BatteryStatus) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        status.cycleCount = IORegistry.property(service, "CycleCount") as? Int
        if let data = IORegistry.property(service, "BatteryData") as? [String: Any],
           let design = data["DesignCapacity"] as? Int, design > 0,
           let capacity = (data["NominalChargeCapacity"] as? Int) ?? (data["FullChargeCapacity"] as? Int) {
            status.health = min(1, Double(capacity) / Double(design))
        }
        if let adapter = IORegistry.property(service, "AdapterDetails") as? [String: Any] {
            status.adapterWatts = adapter["Watts"] as? Int
        }
    }
}

// MARK: - GPU

public enum GPUSampler {
    public static func sample() -> GPUUsage? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: GPUUsage?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // 只读取需要的属性，避免复制整张属性表
            guard let stats = IORegistry.property(service, "PerformanceStatistics") as? [String: Any],
                  let utilization = stats["Device Utilization %"] as? Int else { continue }
            let usage = GPUUsage(name: IORegistry.property(service, "model") as? String ?? "GPU",
                                 utilization: Double(min(100, max(0, utilization))) / 100,
                                 coreCount: IORegistry.property(service, "gpu-core-count") as? Int)
            if best == nil || usage.utilization > best!.utilization { best = usage }
        }
        return best
    }
}

// MARK: - 系统信息

public enum SystemInfoReader {
    public static func read() -> SystemInfo {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        var modelName = Sysctl.string("hw.model") ?? "Mac"
        if product != 0 {
            if let name = IORegistry.string(fromData: IORegistry.property(product, "product-name")), !name.isEmpty {
                modelName = name
            }
            IOObjectRelease(product)
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let boot = sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0
            ? Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec)) : nil

        var info = SystemInfo(modelName: modelName,
                              osVersion: "macOS \(version.majorVersion).\(version.minorVersion)\(patch)",
                              bootDate: boot)
        info.modelIdentifier = Sysctl.string("hw.model") ?? ""
        info.osBuild = Sysctl.string("kern.osversion") ?? ""
        let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if platform != 0 {
            info.serialNumber = IORegistryEntryCreateCFProperty(platform, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            IOObjectRelease(platform)
        }
        return info
    }
}
