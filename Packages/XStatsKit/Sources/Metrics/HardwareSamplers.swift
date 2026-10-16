// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import IOKit
import IOKit.ps
import Localization

// MARK: - 磁盘

public enum DiskSampler {
  public static func sample(volume: URL = URL(fileURLWithPath: "/"), includeBreakdown: Bool = false)
    -> DiskUsage?
  {
    let keys: Set<URLResourceKey> = [
      .volumeLocalizedNameKey, .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ]
    guard let values = try? volume.resourceValues(forKeys: keys),
      let total = values.volumeTotalCapacity
    else { return nil }
    // “重要用途可用空间”包含可清除空间，与访达显示一致；减去普通可用空间就是可清除的部分
    let available = max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)
    let strict = Int64(values.volumeAvailableCapacity ?? 0)
    var usage = DiskUsage(
      volumeName: values.volumeLocalizedName ?? tr("磁盘"),
      total: UInt64(total), available: UInt64(available),
      purgeable: UInt64(max(0, available - strict)))
    if includeBreakdown, volume.path == "/" { usage.breakdown = DiskBreakdown.read(usage) }
    return usage
  }
}

// MARK: - 电池

public enum BatterySampler {
  public static func sample() -> BatteryStatus? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }

    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
          as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
      else { continue }

      let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
      let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
      let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
      let pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
      let charged = description[kIOPSIsChargedKey] as? Bool ?? false
      let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
      let minutes = (description[minutesKey] as? Int).flatMap { $0 > 0 ? $0 : nil }

      var status = BatteryStatus(
        level: maximum > 0 ? Double(current) / Double(maximum) : 0,
        isCharging: isCharging, isPluggedIn: pluggedIn, isFullyCharged: charged,
        minutesRemaining: pluggedIn && !isCharging ? nil : minutes)
      fillRegistryDetails(&status)
      return status
    }
    return nil
  }

  private static func fillRegistryDetails(_ status: inout BatteryStatus) {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return }
    defer { IOObjectRelease(service) }

    // 只复制电池详情用到的属性，不读取整张设备表。
    let keys = [
      "CycleCount", "BatteryData", "Voltage", "InstantAmperage", "Amperage", "AdapterDetails",
    ]
    let properties = Dictionary(
      uniqueKeysWithValues: keys.compactMap { key in
        IORegistry.property(service, key).map { (key, $0) }
      })
    applyRegistryDetails(properties, to: &status)
  }

  static func applyRegistryDetails(_ properties: [String: Any], to status: inout BatteryStatus) {
    status.cycleCount = properties["CycleCount"] as? Int
    let data = properties["BatteryData"] as? [String: Any] ?? [:]
    status.designCapacity = (data["DesignCapacity"] as? Int).flatMap { $0 > 0 ? $0 : nil }
    status.fullChargeCapacity =
      ((data["NominalChargeCapacity"] as? Int)
      ?? (data["FullChargeCapacity"] as? Int)).flatMap { $0 > 0 ? $0 : nil }
    status.health = nil
    if let design = status.designCapacity, let capacity = status.fullChargeCapacity {
      status.health = min(1, Double(capacity) / Double(design))
    }
    status.voltage = (properties["Voltage"] as? Int).flatMap { $0 > 0 ? Double($0) / 1000 : nil }
    // IOKit 有时以 UInt64 存储负数，NSNumber.int64Value 保留二进制符号。
    status.amperage = ((properties["InstantAmperage"] ?? properties["Amperage"]) as? NSNumber)
      .map { Double($0.int64Value) / 1000 }
    status.adapterWatts = (properties["AdapterDetails"] as? [String: Any])?["Watts"] as? Int
  }

}

// MARK: - GPU

public enum GPUSampler {
  public static func sample() -> GPUUsage? {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
    else {
      return nil
    }
    defer { IOObjectRelease(iterator) }

    var best: GPUUsage?
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      // 只读取需要的属性，避免复制整张属性表
      guard let stats = IORegistry.property(service, "PerformanceStatistics") as? [String: Any],
        let usage = usage(
          name: IORegistry.property(service, "model") as? String ?? "GPU",
          coreCount: IORegistry.property(service, "gpu-core-count") as? Int,
          statistics: stats)
      else { continue }
      if best == nil || usage.utilization > best!.utilization { best = usage }
    }
    return best
  }

  static func usage(name: String, coreCount: Int?, statistics: [String: Any]) -> GPUUsage? {
    guard let utilization = statistics["Device Utilization %"] as? Int else { return nil }
    var usage = GPUUsage(
      name: name, utilization: Double(min(100, max(0, utilization))) / 100, coreCount: coreCount)
    usage.rendererUtilization = (statistics["Renderer Utilization %"] as? Int).map {
      Double(min(100, max(0, $0))) / 100
    }
    usage.tilerUtilization = (statistics["Tiler Utilization %"] as? Int).map {
      Double(min(100, max(0, $0))) / 100
    }
    usage.memoryInUse = (statistics["In use system memory"] as? Int).flatMap {
      $0 >= 0 ? UInt64($0) : nil
    }
    return usage
  }

}

// MARK: - 系统信息

public enum SystemInfoReader {
  public static func read() -> SystemInfo {
    let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
    var modelName = Sysctl.string("hw.model") ?? "Mac"
    if product != 0 {
      if let name = IORegistry.string(fromData: IORegistry.property(product, "product-name")),
        !name.isEmpty
      {
        modelName = name
      }
      IOObjectRelease(product)
    }

    let version = ProcessInfo.processInfo.operatingSystemVersion
    let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
    var bootTime = timeval()
    var size = MemoryLayout<timeval>.size
    let boot =
      sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0
      ? Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec)) : nil

    var info = SystemInfo(
      modelName: modelName,
      osVersion: "macOS \(version.majorVersion).\(version.minorVersion)\(patch)",
      bootDate: boot)
    info.modelIdentifier = Sysctl.string("hw.model") ?? ""
    info.osBuild = Sysctl.string("kern.osversion") ?? ""
    let platform = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    if platform != 0 {
      info.serialNumber =
        IORegistryEntryCreateCFProperty(
          platform, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
      IOObjectRelease(platform)
    }
    // 静态硬件属性不依赖 PerformanceStatistics，关闭 GPU 监控时也能显示。
    let accelerator = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    if accelerator != 0 {
      let model = IORegistry.property(accelerator, "model")
      info.gpuName = (model as? String) ?? IORegistry.string(fromData: model)
      info.gpuCoreCount = IORegistry.property(accelerator, "gpu-core-count") as? Int
      IOObjectRelease(accelerator)
    }
    return info
  }
}
