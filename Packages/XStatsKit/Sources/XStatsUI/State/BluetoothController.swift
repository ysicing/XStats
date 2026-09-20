import Foundation
import Metrics
import Observation

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

    /// 电量最低的一块电池（耳机的左右耳、充电盒分别算）
    public var lowest: (device: BluetoothDevice, label: String, percent: Int)? {
        var best: (device: BluetoothDevice, label: String, percent: Int)?
        for device in devices ?? [] {
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
        devices = await Task.detached(priority: .utility) { BluetoothBatteryReader.read() }.value
        updatedAt = Date()
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
