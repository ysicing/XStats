import Foundation
import IOKit

/// 启动磁盘的 NVMe SMART 健康信息
public struct DiskHealth: Sendable, Equatable {
    public var model: String
    /// 已消耗的寿命（厂商估算，可以超过 100）
    public var percentageUsed: Int
    public var availableSpare: Int
    public var availableSpareThreshold: Int
    public var temperature: Double?
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var powerOnHours: UInt64
    public var powerCycles: UInt64
    public var unsafeShutdowns: UInt64
    public var mediaErrors: UInt64
    public var criticalWarning: UInt8

    public var remainingLife: Int { max(0, 100 - percentageUsed) }
}

/// 通过系统自带的 NVMeSMARTLib 插件读取 SMART，不需要 root
public enum DiskHealthReader {
    public static func read() -> DiskHealth? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let capable = IORegistryEntryCreateCFProperty(service, "NVMe SMART Capable" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool, capable,
                  let bytes = smartData(for: service) else { continue }
            // 型号在上层的 NVMe 控制器上
            let model = (IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Model Number" as CFString, kCFAllocatorDefault,
                                                         IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String)?
                .trimmingCharacters(in: .whitespaces) ?? "SSD"
            return parse(bytes, model: model)
        }
        return nil
    }

    /// NVMe 1.0c 5.10.1.2：512 字节 SMART / Health 日志，小端，无对齐填充
    static func parse(_ data: [UInt8], model: String) -> DiskHealth? {
        guard data.count >= 192 else { return nil }
        func u64(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << (8 * UInt64($1)) }
        }
        let kelvin = Double(UInt16(data[1]) | UInt16(data[2]) << 8)
        // 数据单位为 1000 个 512 字节扇区
        let unit: UInt64 = 512 * 1000
        return DiskHealth(model: model,
                          percentageUsed: Int(data[5]),
                          availableSpare: Int(data[3]),
                          availableSpareThreshold: Int(data[4]),
                          temperature: kelvin > 200 ? kelvin - 273.15 : nil,
                          bytesRead: u64(32).multipliedReportingOverflow(by: unit).partialValue,
                          bytesWritten: u64(48).multipliedReportingOverflow(by: unit).partialValue,
                          powerOnHours: u64(128),
                          powerCycles: u64(112),
                          unsafeShutdowns: u64(144),
                          mediaErrors: u64(160),
                          criticalWarning: data[0])
    }

    private static func smartData(for service: io_service_t) -> [UInt8]? {
        // kIOCFPlugInInterfaceID、kIONVMeSMARTUserClientTypeID、kIONVMeSMARTInterfaceID 是 C 宏，Swift 里按字节重建
        let pluginInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                                               0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
        let userClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
                                                              0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
        let smartInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
                                                              0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, userClientTypeID, pluginInterfaceID, &plugin, &score) == KERN_SUCCESS,
              let plugin, let vtable = plugin.pointee?.pointee else { return nil }
        defer { _ = vtable.Release(plugin) }

        var smart: LPVOID?
        guard vtable.QueryInterface(plugin, CFUUIDGetUUIDBytes(smartInterfaceID), &smart) == S_OK, let smart else { return nil }
        // IONVMeSMARTInterface：IUNKNOWN_C_GUTS（4 个指针）、version、revision，之后第一个函数是 SMARTReadData
        let interface = smart.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
        let table = interface.pointee
        typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
        typealias ReadData = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
        defer { _ = table.load(fromByteOffset: 24, as: Release.self)(smart) }
        let readData = table.load(fromByteOffset: 40, as: ReadData.self)
        var buffer = [UInt8](repeating: 0, count: 512)
        let result = buffer.withUnsafeMutableBytes { readData(smart, $0.baseAddress) }
        return result == kIOReturnSuccess ? buffer : nil
    }
}

/// 所有块设备的读写速率（字节 / 秒）
public struct DiskActivity: Sendable, Equatable {
    public var readRate: Double
    public var writeRate: Double
}

/// 读取 IOBlockStorageDriver 的累计读写字节数，两次采样相减得到速率
public struct DiskActivitySampler {
    private var previous: (date: Date, read: UInt64, write: UInt64)?

    public init() {}

    public mutating func sample(now: Date = Date()) -> DiskActivity? {
        guard let totals = Self.totals() else { return nil }
        defer { previous = (now, totals.read, totals.write) }
        guard let previous, now > previous.date else { return nil }
        let seconds = now.timeIntervalSince(previous.date)
        // 磁盘被推出后累计值会变小，这一次不计
        guard totals.read >= previous.read, totals.write >= previous.write, seconds < 60 else { return nil }
        return DiskActivity(readRate: Double(totals.read - previous.read) / seconds,
                            writeRate: Double(totals.write - previous.write) / seconds)
    }

    static func totals() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var write: UInt64 = 0
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            read &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}
