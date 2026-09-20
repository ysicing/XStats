import AppKit
import Foundation
import Localization
import Metrics
import Network
import Observation
import UserNotifications

/// 可以发系统通知的状况
public enum AlertKind: String, CaseIterable, Identifiable, Sendable {
    case cpuTemperature, cpuLoad, memoryPressure, diskSpace, networkDown, batteryHealth, bluetoothBattery

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuTemperature: tr("CPU 过热")
        case .cpuLoad: tr("CPU 持续高负载")
        case .memoryPressure: tr("内存压力严重")
        case .diskSpace: tr("磁盘空间不足")
        case .networkDown: tr("网络断开")
        case .batteryHealth: tr("电池健康度下降")
        case .bluetoothBattery: tr("蓝牙设备电量低")
        }
    }

    var detail: String {
        switch self {
        case .cpuTemperature: tr("CPU 温度持续 1 分钟高于设定值")
        case .cpuLoad: tr("CPU 总占用持续 1 分钟高于设定值，通常是某个应用卡住或在后台狂跑")
        case .memoryPressure: tr("内存压力持续 30 秒处于严重，系统开始大量换页")
        case .diskSpace: tr("启动磁盘可用空间低于 10% 或 10 GB，每 10 分钟检查一次")
        case .networkDown: tr("网络连接中断超过 20 秒，恢复后再提示一次")
        case .batteryHealth: tr("电池最大容量低于 80%，每 30 天最多提醒一次")
        case .bluetoothBattery: tr("已连接的键盘、鼠标、耳机等电量低于 15%，每 10 分钟检查一次")
        }
    }

    var symbol: String {
        switch self {
        case .cpuTemperature: "thermometer.high"
        case .cpuLoad: "cpu"
        case .memoryPressure: "memorychip"
        case .diskSpace: "internaldrive"
        case .networkDown: "wifi.slash"
        case .batteryHealth: "battery.25percent"
        case .bluetoothBattery: "dot.radiowaves.left.and.right"
        }
    }

    /// 点通知打开的页面
    var tab: PanelTab {
        switch self {
        case .cpuTemperature: .thermal
        case .cpuLoad: .cpu
        case .memoryPressure: .memory
        case .diskSpace: .disk
        case .networkDown: .network
        case .batteryHealth, .bluetoothBattery: .system
        }
    }

    /// 状况持续多久才提醒
    var sustain: TimeInterval {
        switch self {
        case .cpuTemperature, .cpuLoad: 60
        case .memoryPressure: 30
        case .networkDown: 20
        case .diskSpace, .batteryHealth, .bluetoothBattery: 0
        }
    }

    /// 同一状况两次提醒的最短间隔
    var cooldown: TimeInterval {
        switch self {
        case .cpuTemperature, .cpuLoad, .memoryPressure, .networkDown: 30 * 60
        case .diskSpace, .bluetoothBattery: 6 * 60 * 60
        case .batteryHealth: 30 * 24 * 60 * 60
        }
    }
}

/// 一种状况的触发判断：持续满 sustain 秒才触发，同一段持续期内只触发一次，两次之间至少间隔 cooldown
struct AlertTracker: Equatable {
    private(set) var activeSince: Date?
    private(set) var firedThisEpisode = false
    private(set) var lastFired: Date?

    /// 返回 true 表示现在应该发通知
    mutating func update(isActive: Bool, now: Date, sustain: TimeInterval, cooldown: TimeInterval) -> Bool {
        guard isActive else {
            activeSince = nil
            firedThisEpisode = false
            return false
        }
        let since = activeSince ?? now
        activeSince = since
        guard !firedThisEpisode, now.timeIntervalSince(since) >= sustain else { return false }
        if let lastFired, now.timeIntervalSince(lastFired) < cooldown { return false }
        firedThisEpisode = true
        lastFired = now
        return true
    }
}

/// 判断各项状况并发出系统通知；点通知打开主窗口的对应页面
@MainActor
@Observable
public final class AlertController: NSObject {
    public enum Authorization: Equatable {
        case unknown, allowed, denied
    }

    public private(set) var authorization: Authorization = .unknown

    @ObservationIgnored var openTab: (PanelTab) -> Void = { _ in }
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var trackers: [AlertKind: AlertTracker] = [:]
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkNotified = false
    @ObservationIgnored private var networkDownTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    /// 每个蓝牙设备上次提醒的时间
    @ObservationIgnored private var bluetoothNotified: [String: Date] = [:]

    /// 单元测试与截图进程没有应用包标识，不能使用通知中心
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        super.init()
    }

    func start() {
        center?.delegate = self
        refreshAuthorization()
        applySettings()
    }

    /// 开关变化后启动或停止网络监听与定期检查；首次打开任一提醒时请求通知权限
    func applySettings() {
        let enabled = settings.enabledAlerts
        if !enabled.isEmpty, authorization == .unknown { requestAuthorization() }

        if enabled.contains(.networkDown) {
            if pathMonitor == nil { startNetworkMonitor() }
        } else {
            pathMonitor?.cancel()
            pathMonitor = nil
            networkDownTask?.cancel()
            networkNotified = false
        }

        if enabled.contains(.diskSpace) || enabled.contains(.batteryHealth) || enabled.contains(.bluetoothBattery) {
            if periodicTask == nil {
                periodicTask = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.checkPeriodic()
                        await self?.checkBluetooth()
                        try? await Task.sleep(for: .seconds(10 * 60), tolerance: .seconds(60))
                    }
                }
            }
        } else {
            periodicTask?.cancel()
            periodicTask = nil
        }
    }

    // MARK: 判断

    /// 每次采样后调用
    func evaluate(_ store: MetricsStore, now: Date = Date()) {
        let enabled = settings.enabledAlerts
        guard !enabled.isEmpty else { return }
        if enabled.contains(.cpuTemperature),
           let cpu = store.sensors?.temperatures.first(where: { $0.group == .cpu })?.maximum {
            let limit = Double(settings.alertCPUTemperature)
            fireIfNeeded(.cpuTemperature, isActive: cpu >= limit, now: now,
                         body: tr("CPU 温度 \(Format.temperature(cpu, fahrenheit: settings.useFahrenheit))，已持续超过 1 分钟。可以检查高占用进程，或在“温度与风扇”里提高风扇转速。"))
        }
        if enabled.contains(.cpuLoad), let cpu = store.cpu {
            // 只在菜单栏显示时进程列表可能是很久以前采的，不在通知里点名应用，让用户打开详情看实时的
            let limit = Double(settings.alertCPULoad) / 100
            fireIfNeeded(.cpuLoad, isActive: cpu.total >= limit, now: now,
                         body: tr("CPU 占用 \(Format.percent(cpu.total))，已持续超过 1 分钟。可以打开 CPU 详情，在“按应用汇总”里看看是哪个应用在占用。"))
        }
        if enabled.contains(.memoryPressure), let memory = store.memory {
            fireIfNeeded(.memoryPressure, isActive: memory.pressure == .critical, now: now,
                         body: tr("可用内存只剩 \(Format.bytes(memory.available))，系统正在压缩和交换内存。关闭不用的应用可以缓解。"))
        }
    }

    private func checkPeriodic(now: Date = Date()) {
        let enabled = settings.enabledAlerts
        if enabled.contains(.diskSpace), let disk = DiskSampler.sample() {
            let low = disk.total > 0 && (Double(disk.available) / Double(disk.total) < 0.1 || disk.available < 10_000_000_000)
            fireIfNeeded(.diskSpace, isActive: low, now: now,
                         body: tr("“\(disk.volumeName)”只剩 \(Format.bytes(disk.available, base: .decimal)) 可用。可以用 XStats 的清理功能释放缓存。"))
        }
        if enabled.contains(.batteryHealth), let health = BatterySampler.sample()?.health {
            // 冷却时间跨越重启，记在偏好设置里
            let last = defaults.object(forKey: Keys.batteryNotified) as? Date
            if health < 0.8, last.map({ now.timeIntervalSince($0) >= AlertKind.batteryHealth.cooldown }) ?? true {
                defaults.set(now, forKey: Keys.batteryNotified)
                send(.batteryHealth, body: tr("电池最大容量为 \(Format.percent(health))，续航会明显缩短。可以在“系统设置 › 电池”查看是否建议维修。"))
            }
        }
    }

    private func checkBluetooth(now: Date = Date()) async {
        guard settings.enabledAlerts.contains(.bluetoothBattery) else { return }
        let devices = await Task.detached { BluetoothBatteryReader.read() }.value
        for device in devices {
            guard let lowest = device.batteries.min(by: { $0.percent < $1.percent }), lowest.percent <= 15 else {
                bluetoothNotified[device.id] = nil
                continue
            }
            if let last = bluetoothNotified[device.id], now.timeIntervalSince(last) < AlertKind.bluetoothBattery.cooldown { continue }
            bluetoothNotified[device.id] = now
            let part = device.batteries.count > 1 ? "\(lowest.label)" : ""
            send(.bluetoothBattery, title: tr("\(device.name)电量低"), body: tr("\(device.name)\(part)只剩 \(lowest.percent)%，记得充电。"))
        }
    }

    private func fireIfNeeded(_ kind: AlertKind, isActive: Bool, now: Date, body: @autoclosure () -> String) {
        var tracker = trackers[kind] ?? AlertTracker()
        let fire = tracker.update(isActive: isActive, now: now, sustain: kind.sustain, cooldown: kind.cooldown)
        trackers[kind] = tracker
        if fire { send(kind, body: body()) }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "work.12306.xstats.alerts.network"))
        pathMonitor = monitor
    }

    private func networkChanged(satisfied: Bool) {
        networkDownTask?.cancel()
        if satisfied {
            if networkNotified {
                networkNotified = false
                send(.networkDown, title: tr("网络已恢复"), body: tr("网络连接已经恢复。"))
            }
            return
        }
        guard !networkNotified else { return }
        networkDownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AlertKind.networkDown.sustain))
            guard !Task.isCancelled, let self else { return }
            self.networkNotified = true
            Log.network.notice("网络断开超过 20 秒")
            self.send(.networkDown, body: tr("网络连接已中断超过 20 秒。可以打开网络详情查看接口与路由器状态。"))
        }
    }

    // MARK: 通知

    func refreshAuthorization() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                switch status {
                case .authorized, .provisional: self?.authorization = .allowed
                case .denied: self?.authorization = .denied
                default: self?.authorization = .unknown
                }
            }
        }
    }

    func requestAuthorization(then action: (@MainActor () -> Void)? = nil) {
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorization = granted ? .allowed : .denied
                if granted { action?() }
            }
        }
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "work.12306.xstats.app"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 还没询问过权限时先请求，允许后再发
    func sendTest() {
        guard authorization != .unknown else {
            requestAuthorization { [weak self] in self?.sendTest() }
            return
        }
        send(.cpuTemperature, title: tr("XStats 通知测试"), body: tr("通知可以正常显示。发生你打开的状况时，会像这样提醒你。"))
    }

    private func send(_ kind: AlertKind, title: String? = nil, body: String) {
        guard let center else { return }
        Log.app.notice("发送通知：\(kind.rawValue, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = title ?? kind.title
        content.body = body
        content.sound = .default
        content.userInfo = ["tab": kind.tab.rawValue]
        // 同一种状况用固定标识，新的提醒替换旧的，不在通知中心堆积
        center.add(UNNotificationRequest(identifier: "xstats.\(kind.rawValue)", content: content, trigger: nil))
    }

    private enum Keys {
        static let batteryNotified = "alertBatteryHealthNotified"
    }
}

extension AlertController: UNUserNotificationCenterDelegate {
    /// 应用在前台时也显示横幅
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                                   withCompletionHandler completionHandler: @escaping () -> Void) {
        let tab = (response.notification.request.content.userInfo["tab"] as? String).flatMap(PanelTab.init(rawValue:))
        completionHandler()
        guard let tab else { return }
        Task { @MainActor [weak self] in self?.openTab(tab) }
    }
}
