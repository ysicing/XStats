import Foundation
import IOKit
import Localization

/// 已连接蓝牙设备的电量
public struct BluetoothDevice: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case keyboard, mouse, trackpad, headphones, phone, other
    }

    public var id: String { address.isEmpty ? name : address }
    public var name: String
    public var address: String
    public var kind: Kind
    /// 电量（0...100）；耳机分左耳、右耳、充电盒
    public var batteries: [(label: String, percent: Int)]

    public static func == (lhs: BluetoothDevice, rhs: BluetoothDevice) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.kind == rhs.kind
            && lhs.batteries.map(\.label) == rhs.batteries.map(\.label) && lhs.batteries.map(\.percent) == rhs.batteries.map(\.percent)
    }
}

/// 电量来自两处：system_profiler 的蓝牙信息（AirPods 等耳机的左右耳与充电盒）和 IOKit 里 Apple 键盘、鼠标、触控板的 BatteryPercent
public enum BluetoothBatteryReader {
    public static func read() -> [BluetoothDevice] {
        var devices = parseSystemProfiler(runSystemProfiler())
        for (product, percent) in hidBatteries() {
            if let index = devices.firstIndex(where: { $0.name == product }) {
                if devices[index].batteries.isEmpty { devices[index].batteries = [(tr("电量"), percent)] }
            } else {
                devices.append(BluetoothDevice(name: product, address: "", kind: kind(forName: product, minorType: nil), batteries: [(tr("电量"), percent)]))
            }
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `system_profiler SPBluetoothDataType -json` 里 device_connected 分组的设备
    static func parseSystemProfiler(_ data: Data) -> [BluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [BluetoothDevice] = []
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let labels: [(String, String)] = [("device_batteryLevelMain", tr("电量")), ("device_batteryLevel", tr("电量")),
                                                      ("device_batteryLevelLeft", tr("左耳")), ("device_batteryLevelRight", tr("右耳")),
                                                      ("device_batteryLevelCase", tr("充电盒"))]
                    var batteries: [(String, Int)] = []
                    for (key, label) in labels {
                        if let percent = percentValue(info[key]), !batteries.contains(where: { $0.0 == label }) {
                            batteries.append((label, percent))
                        }
                    }
                    devices.append(BluetoothDevice(name: name, address: info["device_address"] as? String ?? "",
                                                   kind: kind(forName: name, minorType: info["device_minorType"] as? String),
                                                   batteries: batteries))
                }
            }
        }
        return devices
    }

    static func percentValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return (0...100).contains(number) ? number : nil }
        guard let text = value as? String, let number = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
        return (0...100).contains(number) ? number : nil
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

    private static func hidBatteries() -> [(String, Int)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var results: [(String, Int)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int,
                  let product = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  (0...100).contains(percent), !results.contains(where: { $0.0 == product }) else { continue }
            results.append((product, percent))
        }
        return results
    }
}
