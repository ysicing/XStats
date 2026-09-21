import Foundation
import Metrics
import Observation

/// 短暂休眠或切换到其他设备时保留最近电量；过期设备不会继续伪装成实时读数。
struct BluetoothDeviceCache {
    let retention: TimeInterval
    private var entries: [String: (device: BluetoothDevice, lastSeen: Date)] = [:]

    init(retention: TimeInterval = 30 * 60) {
        self.retention = retention
    }

    mutating func merge(current: [BluetoothDevice], now: Date) -> [BluetoothDevice] {
        entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) <= retention }
        let currentNameCounts = Dictionary(grouping: current, by: Self.normalizedName).mapValues(\.count)
        var currentKeys = Set<String>()
        var result: [BluetoothDevice] = []
        for var device in current {
            var key = Self.key(for: device)
            if entries[key] == nil, currentNameCounts[Self.normalizedName(device)] == 1 {
                let candidates = entries.filter {
                    Self.normalizedName($0.value.device) == Self.normalizedName(device)
                        && (device.address.isEmpty || $0.value.device.address.isEmpty)
                }
                if candidates.count == 1, let previous = candidates.first {
                    entries[previous.key] = nil
                    if device.address.isEmpty { device.address = previous.value.device.address }
                    key = Self.key(for: device)
                }
            }
            currentKeys.insert(key)
            device.isConnected = true
            device.lastSeen = nil
            entries[key] = (device, now)
            result.append(device)
        }

        for (key, entry) in entries where !currentKeys.contains(key) {
            var device = entry.device
            device.isConnected = false
            device.lastSeen = entry.lastSeen
            result.append(device)
        }
        return result.sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func key(for device: BluetoothDevice) -> String {
        device.id
    }

    private static func normalizedName(_ device: BluetoothDevice) -> String {
        device.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// 已连接蓝牙设备的电量。读取要起 system_profiler、一次一两秒，所以只在有人看或菜单栏需要时轮询
@MainActor
@Observable
public final class BluetoothController {
    public enum Demand: Equatable, Sendable {
        /// 不轮询
        case off
        /// 菜单栏需要（电量低提示、没有电池的 Mac 显示设备电量）：每 5 分钟
        case background
        /// 电池弹窗 / 页面、本机信息页打开着：每分钟
        case foreground

        var interval: Duration? {
            switch self {
            case .off: nil
            case .background: .seconds(300)
            case .foreground: .seconds(60)
            }
        }
    }

    /// nil 表示还没读过
    public private(set) var devices: [BluetoothDevice]?
    public private(set) var updatedAt: Date?
    public private(set) var isReading = false
    @ObservationIgnored private var demand: Demand = .off
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deviceCache = BluetoothDeviceCache()

    /// 电量最低的一块电池（耳机的左右耳、充电盒分别算）
    public var lowest: (device: BluetoothDevice, label: String, percent: Int)? {
        Self.lowest(in: devices ?? [])
    }

    static func lowest(in devices: [BluetoothDevice]) -> (device: BluetoothDevice, label: String, percent: Int)? {
        var best: (device: BluetoothDevice, label: String, percent: Int)?
        for device in devices where device.isConnected {
            for battery in device.batteries {
                if let current = best, battery.percent >= current.percent { continue }
                best = (device, battery.label, battery.percent)
            }
        }
        return best
    }

    func setDemand(_ demand: Demand) {
        guard demand != self.demand else { return }
        self.demand = demand
        task?.cancel()
        task = nil
        guard let interval = demand.interval else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.read()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 弹窗里的刷新按钮
    func refresh() {
        Task { await read() }
    }

    private func read() async {
        guard !isReading else { return }
        isReading = true
        let current = await Task.detached(priority: .utility) { BluetoothBatteryReader.read() }.value
        let now = Date()
        devices = deviceCache.merge(current: current, now: now)
        updatedAt = now
        isReading = false
    }
}

extension BluetoothDevice.Kind {
    /// 列表与菜单栏里代表设备类型的图标
    var symbol: String {
        switch self {
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .headphones: "headphones"
        case .phone: "iphone"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}
