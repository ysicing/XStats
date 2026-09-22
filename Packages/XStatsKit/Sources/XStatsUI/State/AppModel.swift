import AIUsage
import Foundation
import Metrics
import Observation
import ServiceManagement
import SMC
import Updates

/// 应用状态总入口，注入到所有 SwiftUI 视图
@MainActor
@Observable
public final class AppModel {
    public let settings: AppSettings
    public let aiUsage: AIUsageController
    public let store: MetricsStore
    public let helper: HelperClient
    public let fans: FanController
    public let keepAwake: KeepAwakeController
    public let cleaner: CleanerController
    public let maintenance: MaintenanceController
    public let network: NetworkController
    public let egress = EgressController()
    public let speedTest: SpeedTestController
    public let explainer = ProcessExplainer()
    public let updates: UpdateController
    let diagnostics = DiagnosticsExporter()
    public let alerts: AlertController
    public let uninstaller = UninstallerController()
    public let bluetooth = BluetoothController()
    let startupItems = StartupItemsController()
    public let history: HistoryRecorder
    public let sync: SyncController
    let diskTools: DiskToolsController
    @ObservationIgnored public let hub = MetricsHub()

    public var isMainWindowVisible = false
    /// 被其他应用占用、没能注册的快捷键
    public var hotKeyConflicts: Set<HotKeyAction> = []
    /// 当前打开的菜单栏详情弹窗；合并模式的弹窗切到某一项时也是这一项
    public var openPopover: MenuBarItem?
    /// 合并模式下点击菜单栏图标弹出的面板正在显示。
    /// 面板切到某一项的详情时 openPopover 就是这一项，按那一项的弹窗加采数据；总览只用菜单栏本来就在采的指标
    public var isCombinedPopoverOpen = false {
        didSet {
            guard isCombinedPopoverOpen != oldValue else { return }
            if isCombinedPopoverOpen {
                openPopover = combinedPopoverTab
            } else if openPopover == combinedPopoverTab {
                openPopover = nil
            }
        }
    }
    /// 合并模式面板当前的标签：nil 是状态总览，否则是某一项的详情
    public var combinedPopoverTab: MenuBarItem? {
        didSet { if isCombinedPopoverOpen { openPopover = combinedPopoverTab } }
    }
    public private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    public private(set) var launchAtLoginError: String?

    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var openMainWindow: (PanelTab?) -> Void = { _ in }
    @ObservationIgnored var openEgressWindow: () -> Void = {}
    @ObservationIgnored var openSpeedTestWindow: () -> Void = {}
    @ObservationIgnored var quit: () -> Void = {}

    public init(settings: AppSettings = AppSettings(), historyURL: URL? = HistoryDatabase.defaultURL,
                aiUsageProviders: [any AIUsageProvider] = [CodexLocalUsageProvider(), ClaudeLocalUsageProvider()]) {
        let store = MetricsStore()
        let helper = HelperClient()
        self.settings = settings
        aiUsage = AIUsageController(settings: settings, providers: aiUsageProviders)
        self.store = store
        self.helper = helper
        fans = FanController(helper: helper, store: store, settings: settings)
        keepAwake = KeepAwakeController(helper: helper, settings: settings)
        cleaner = CleanerController(settings: settings)
        maintenance = MaintenanceController(helper: helper)
        network = NetworkController(settings: settings)
        updates = UpdateController(settings: settings)
        alerts = AlertController(settings: settings)
        history = HistoryRecorder(settings: settings, databaseURL: historyURL)
        sync = SyncController(settings: settings)
        diskTools = DiskToolsController(helper: helper)
        speedTest = SpeedTestController(settings: settings)
    }

    /// 根据当前可见内容决定采集范围：主窗口看标签页，详情弹窗看是哪一项
    var demand: MetricsDemand {
        var demand = MetricsDemand()
        let tab = settings.panelTab
        let window = isMainWindowVisible
        let popover = openPopover
        let menu = settings.menuBarItems
        let thermalPopover = popover == .temperature || popover == .fan

        // 进程页要读全系统进程（启动 ps），每 2 秒刷新一次足够，也更省电
        demand.interval = window && tab == .processes && popover == nil ? .seconds(2)
            : window || popover != nil || isCombinedPopoverOpen ? .seconds(1) : .seconds(settings.refreshSeconds)
        demand.memory = true
        demand.network = true
        let showing = { (page: PanelTab, item: MenuBarItem) in (window && tab == page) || popover == item }
        demand.gpu = (window && [.overview, .system].contains(tab)) || menu.contains(.gpu) || showing(.gpu, .gpu)
        demand.disk = (window && [.overview, .system, .cleaner, .disk].contains(tab)) || menu.contains(.disk) || popover == .disk
        demand.diskDetail = showing(.disk, .disk)
        demand.battery = (window && [.overview, .system, .keepAwake].contains(tab)) || keepAwake.lidClosedActive
            || menu.contains(.battery) || showing(.battery, .battery)
        demand.processes = (window && [.processes, .overview, .disk].contains(tab)) || showing(.cpu, .cpu) || showing(.memory, .memory)
            || popover == .disk
        demand.systemProcesses = window && tab == .processes

        var groups = Set<TemperatureGroup>()
        if window && tab == .overview { groups.formUnion([.cpu, .gpu]) }
        if (window && tab == .thermal) || thermalPopover { groups.formUnion(TemperatureGroup.allCases) }
        if menu.contains(.temperature) || fans.mode != .automatic || showing(.cpu, .cpu) { groups.insert(.cpu) }
        if showing(.gpu, .gpu) { groups.insert(.gpu) }
        if showing(.battery, .battery) { groups.insert(.battery) }
        if settings.enabledAlerts.contains(.cpuTemperature) { groups.insert(.cpu) }
        demand.temperatures = groups
        demand.power = (window && tab == .thermal) || thermalPopover || showing(.battery, .battery)
        demand.cpuFrequency = showing(.cpu, .cpu)
        demand.fans = (window && (tab == .thermal || tab == .overview)) || menu.contains(.fan)
            || fans.mode != .automatic || thermalPopover
        return demand
    }

    /// 蓝牙电量读取很慢，只在需要时轮询：电池弹窗 / 页面、本机信息页打开时每分钟；
    /// 菜单栏开着电池项且要做低电量提示、或这台 Mac 没有电池时每 5 分钟
    var bluetoothDemand: BluetoothController.Demand {
        if (isMainWindowVisible && [.battery, .system].contains(settings.panelTab)) || openPopover == .battery { return .foreground }
        if settings.menuBarItems.contains(.battery) && (settings.bluetoothLowBatteryInMenuBar || store.battery == nil) { return .background }
        return .off
    }

    /// 网络详情（接口、公网 IP、进程流量）正在显示
    var isNetworkDetailVisible: Bool {
        openPopover == .network || (isMainWindowVisible && settings.panelTab == .network)
    }

    func refreshLaunchAtLogin() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    /// 快捷切换风扇：未安装辅助工具时打开散热页引导安装
    func requestFanMode(_ mode: FanController.Mode) {
        guard helper.isReady else {
            settings.panelTab = .thermal
            if !isMainWindowVisible { openMainWindow(.thermal) }
            return
        }
        Task { await fans.select(mode) }
    }

    /// 概览页快捷开关合盖运行：同时开启防休眠
    func requestLidMode(_ enabled: Bool) {
        guard helper.isReady else {
            settings.panelTab = .keepAwake
            if !isMainWindowVisible { openMainWindow(.keepAwake) }
            return
        }
        Task {
            await keepAwake.setLidClosed(enabled)
            if enabled, !keepAwake.isActive { await keepAwake.start() }
        }
    }

    /// 用 Apple 智能解释进程：结果显示在主窗口的进程页
    func explainProcess(_ subject: ProcessExplainer.Subject) {
        settings.panelTab = .processes
        if !isMainWindowVisible { openMainWindow(.processes) }
        explainer.explain(subject)
    }

    func handle(_ snapshot: MetricsSnapshot) {
        store.apply(snapshot)
        fans.evaluateSafety()
        keepAwake.evaluateBattery(store.battery)
        alerts.evaluate(store)
        history.record(snapshot)
    }
}
