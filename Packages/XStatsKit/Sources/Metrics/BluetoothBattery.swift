import Foundation
import IOKit
import Localization

/// 蓝牙设备的当前或最近电量
public struct BluetoothDevice: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case keyboard, mouse, trackpad, headphones, phone, other
    }

    public var id: String {
        let normalizedAddress = address.lowercased().filter(\.isHexDigit)
        if !normalizedAddress.isEmpty { return "address:\(normalizedAddress)" }
        let normalizedName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return "name:\(normalizedName)"
    }
    public var name: String
    public var address: String
    public var kind: Kind
    /// 电量（0...100）；耳机分左耳、右耳、充电盒
    public var batteries: [(label: String, percent: Int)]
    /// false 表示设备最近出现过，但当前读取不到；详情页会以“上次电量”展示
    public var isConnected = true
    public var lastSeen: Date? = nil

    public static func == (lhs: BluetoothDevice, rhs: BluetoothDevice) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.kind == rhs.kind
            && lhs.batteries.map(\.label) == rhs.batteries.map(\.label) && lhs.batteries.map(\.percent) == rhs.batteries.map(\.percent)
            && lhs.isConnected == rhs.isConnected && lhs.lastSeen == rhs.lastSeen
    }
}

/// 电量来自三处：system_profiler 的蓝牙信息、pmset 的附件电源，以及 IOKit 的 HID BatteryPercent。
public enum BluetoothBatteryReader {
    public static func read() -> [BluetoothDevice] {
        var devices = parseSystemProfiler(runSystemProfiler())
        devices = merge(devices, with: parsePMSet(runPMSet()))
        devices = merge(devices, with: hidBatteries())
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// system_profiler、pmset 与 IORegistry 对同一设备提供的信息并不完整，按名称合并并保留已有地址。
    static func merge(_ devices: [BluetoothDevice], with additions: [BluetoothDevice]) -> [BluetoothDevice] {
        var result = devices
        for addition in additions {
            let normalizedName = addition.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let nameMatches = result.indices.filter {
                result[$0].name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) == normalizedName
            }
            let index: Int? = if !addition.address.isEmpty {
                result.firstIndex(where: { !$0.address.isEmpty && $0.id == addition.id })
                    ?? nameMatches.first(where: { result[$0].address.isEmpty })
            } else if !addition.name.isEmpty, nameMatches.count == 1 {
                nameMatches[0]
            } else {
                nil
            }

            if let index {
                if result[index].address.isEmpty { result[index].address = addition.address }
                if result[index].batteries.isEmpty { result[index].batteries = addition.batteries }
                if result[index].kind == .other { result[index].kind = addition.kind }
                result[index].isConnected = result[index].isConnected || addition.isConnected
            } else if !addition.name.isEmpty, !addition.address.isEmpty || nameMatches.count <= 1 {
                result.append(addition)
            }
        }
        return result
    }

    /// 读取已连接设备，以及已配对但未连接的键盘、鼠标、触控板和耳机。
    static func parseSystemProfiler(_ data: Data) -> [BluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [BluetoothDevice] = []
        for section in sections {
            func appendDevices(from key: String, isConnected: Bool) {
                for entry in section[key] as? [[String: Any]] ?? [] {
                    for (name, value) in entry {
                        guard let info = value as? [String: Any] else { continue }
                        let kind = kind(forName: name, minorType: info["device_minorType"] as? String)
                        if !isConnected, ![.keyboard, .mouse, .trackpad, .headphones].contains(kind) { continue }
                        let labels: [(String, String)] = [("device_batteryLevelMain", tr("电量")), ("device_batteryLevel", tr("电量")),
                                                          ("device_batteryLevelLeft", tr("左耳")), ("device_batteryLevelRight", tr("右耳")),
                                                          ("device_batteryLevelCase", tr("充电盒"))]
                        var batteries: [(String, Int)] = []
                        for (batteryKey, label) in labels {
                            if let percent = percentValue(info[batteryKey]), !batteries.contains(where: { $0.0 == label }) {
                                batteries.append((label, percent))
                            }
                        }
                        devices.append(BluetoothDevice(name: name, address: info["device_address"] as? String ?? "", kind: kind,
                                                       batteries: batteries, isConnected: isConnected))
                    }
                }
            }

            appendDevices(from: "device_connected", isConnected: true)
            appendDevices(from: "device_not_connected", isConnected: false)
        }
        return devices
    }

    static func percentValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return (0...100).contains(number) ? number : nil }
        guard let text = value as? String else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "%"))
        let normalized = text.trimmingCharacters(in: separators)
        guard let number = Int(normalized) else { return nil }
        return (0...100).contains(number) ? number : nil
    }

    /// `pmset -g accps` 能补充部分 system_profiler / IORegistry 看不到的耳机和第三方 HID 电量。
    /// 无名称的电源项由 IORegistry 提供产品名，这里跳过以免显示成匿名设备。
    static func parsePMSet(_ output: String) -> [BluetoothDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-"), let idRange = line.range(of: "(id=") else { return nil }
            let name = line[line.index(after: line.startIndex)..<idRange.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let close = line[idRange.upperBound...].firstIndex(of: ")") else { return nil }
            let remainder = line[line.index(after: close)...]
            guard let percentText = remainder.split(separator: ";", maxSplits: 1).first,
                  let percent = percentValue(String(percentText)) else { return nil }
            return BluetoothDevice(name: name, address: "", kind: kind(forName: name, minorType: nil),
                                   batteries: [(tr("电量"), percent)])
        }
    }

    static func kind(forName name: String, minorType: String?) -> BluetoothDevice.Kind {
        let text = ((minorType ?? "") + " " + name).lowercased()
        if text.contains("keyboard") { return .keyboard }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") { return .mouse }
        if text.contains("headphone") || text.contains("headset") || text.contains("airpods") || text.contains("beats") { return .headphones }
        if text.contains("phone") { return .phone }
        return .other
    }

    private static func runSystemProfiler() -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        // 最多等 10 秒，蓝牙服务卡住时不拖住采样
        let deadline = DispatchTime.now() + 10
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private static func runPMSet() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "accps"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
    }

    private static func hidBatteries() -> [BluetoothDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var results: [BluetoothDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int,
                  (0...100).contains(percent) else { continue }
            let product = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String ?? ""
            let address = IORegistryEntryCreateCFProperty(service, "DeviceAddress" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String ?? ""
            let category = IORegistryEntryCreateCFProperty(service, "Accessory Category" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            let name = product.isEmpty ? (category ?? "") : product
            let device = BluetoothDevice(name: name, address: address, kind: kind(forName: name, minorType: category),
                                         batteries: [(tr("电量"), percent)])
            guard (!device.name.isEmpty || !device.address.isEmpty), !results.contains(where: { $0.id == device.id }) else { continue }
            results.append(device)
        }
        return results
    }
}
