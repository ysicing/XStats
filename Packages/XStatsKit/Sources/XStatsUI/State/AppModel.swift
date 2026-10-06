import AIUsage
import AppKit
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
    let displays = DisplayController()
    let audio: AudioController
    let connectionMonitor = NetworkMonitorController()
    let networkGeography = NetworkGeographyController()
    public let settings: AppSettings
    let rest: RestController
    let calendarAgenda = CalendarAgendaController()
    public let aiUsage: AIUsageController
    @ObservationIgnored let sub2apiDrafts = Dictionary(uniqueKeysWithValues:
        AIProviderID.allCases.map { ($0, Sub2APIDraft()) })
    public let store: MetricsStore
    public let helper: HelperClient
    public let fans: FanController
    public let keepAwake: KeepAwakeController
    public let cleaner: CleanerController
    let projectPurge: ProjectPurgeController
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
    /// 所有摘要行保持可见，展开项叠加详情需求；关闭后释放整个面板需求。
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
    /// 合并面板当前展开的指标：nil 表示全部收起，同一时间只展开一项。
    public var combinedPopoverTab: MenuBarItem? {
        didSet { if isCombinedPopoverOpen { openPopover = combinedPopoverTab } }
    }
    public private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    public private(set) var launchAtLoginError: String?

    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var openActivityMonitor: () -> Void = {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
    @ObservationIgnored var openCalendar: () -> Void = {}
    @ObservationIgnored var restoreCalendarEntry: () -> Void = {}
    @ObservationIgnored var openAIUsageSettings: () -> Void = {}
    @ObservationIgnored var openMainWindow: (PanelTab?) -> Void = { _ in }
    @ObservationIgnored var openEgressWindow: () -> Void = {}
    @ObservationIgnored var openSpeedTestWindow: () -> Void = {}
    @ObservationIgnored var openProjectPurgeWindow: () -> Void = {}
    @ObservationIgnored var collapseToRestHUD: () -> Void = {}
    @ObservationIgnored var quit: () -> Void = {}

    public init(settings: AppSettings = AppSettings(), historyURL: URL? = HistoryDatabase.defaultURL,
                aiUsageProviders: [any AIUsageProvider] = [CodexLocalUsageProvider(), ClaudeLocalUsageProvider()],
                aiQuotaProviders: [any AIQuotaProvider] = [CodexQuotaProvider(), ClaudeQuotaProvider()],
                quotaCacheURL: URL? = nil) {
        let store = MetricsStore()
        let helper = HelperClient()
        self.settings = settings
        audio = AudioController(defaults: settings.audioDefaults)
        rest = RestController(settings: settings)
        aiUsage = AIUsageController(settings: settings, providers: aiUsageProviders, quotaProviders: aiQuotaProviders,
                                    quotaCacheURL: quotaCacheURL, costReferenceStore: .shared)
        self.store = store
        self.helper = helper
        fans = FanController(helper: helper, store: store, settings: settings)
        keepAwake = KeepAwakeController(helper: helper, settings: settings)
        cleaner = CleanerController(settings: settings)
        projectPurge = ProjectPurgeController(settings: settings)
        maintenance = MaintenanceController(helper: helper)
        network = NetworkController(settings: settings)
        updates = UpdateController(settings: settings)
        alerts = AlertController(settings: settings)
        history = HistoryRecorder(settings: settings, databaseURL: historyURL)
        sync = SyncController(settings: settings)
        diskTools = DiskToolsController(helper: helper)
        speedTest = SpeedTestController(settings: settings)
    }

    /// 硬件能力只影响实际展示，不改写保存的菜单栏偏好。
    var availableMenuBarItems: [MenuBarItem] {
        MenuBarItem.allCases.filter { $0 != .fan || store.supportsFans }
    }

    var visibleMenuBarItems: [MenuBarItem] {
        settings.orderedMenuBarItems.filter { $0 != .fan || store.supportsFans }
    }

    /// 实际绘制读数的项目与面板项目分开，切换为仅图标时不改写用户的项目选择。
    var drawnMenuBarItems: [MenuBarItem] {
        settings.menuBarLayout == .iconOnly ? [] : visibleMenuBarItems
    }

    var isCombinedOverviewVisible: Bool {
        isCombinedPopoverOpen
    }

    var showsOverviewProcesses: Bool {
        combinedPopoverTab == nil && settings.processesEnabled
            && visibleMenuBarItems.contains { $0 == .cpu || $0 == .memory }
    }

    var audioControlsVisible: Bool {
        openPopover == .audio || (isMainWindowVisible && settings.panelTab == .audio)
    }

    var audioMenuVisible: Bool {
        drawnMenuBarItems.contains(.audio) || (isCombinedOverviewVisible && visibleMenuBarItems.contains(.audio))
    }

    var displayControlsVisible: Bool {
        openPopover == .display || (isMainWindowVisible && settings.panelTab == .system)
    }

    /// 根据当前可见内容决定采集范围：主窗口看标签页，详情弹窗看是哪一项
    var demand: MetricsDemand {
        var demand = MetricsDemand()
        let tab = settings.panelTab
        let window = isMainWindowVisible
        let processPage = settings.processesEnabled && window && tab == .processes
        let popover = openPopover
        let menu = Set(drawnMenuBarItems)
        let overview = isCombinedOverviewVisible ? Set(visibleMenuBarItems) : []
        let summary = menu.union(overview)
        let thermalPopover = popover == .temperature || popover == .fan

        // 仅实时监控页需要每秒采样；历史、工具和设置页沿用用户设置的后台间隔。
        let liveWindow = window && [.overview, .system, .cpu, .gpu, .memory, .disk,
                                    .network, .thermal, .battery].contains(tab)
        // AI 用量与显示器有各自的刷新机制，不读取采样结果，不应提高全局采样频率。
        let selfRefreshing: Set<MenuBarItem> = [.aiUsage, .display, .audio]
        let livePopover = popover.map { !selfRefreshing.contains($0) } ?? false
        // 合并面板的摘要始终可见；只有其中的系统指标需要提高全局采样频率。
        let liveOverview = !overview.subtracting(selfRefreshing).isEmpty
        // 进程页要读全系统进程（启动 ps），每 2 秒刷新一次足够，也更省电
        demand.interval = processPage && !livePopover ? .seconds(2)
            : liveWindow || livePopover || liveOverview ? .seconds(1) : .seconds(settings.refreshSeconds)
        demand.memory = true
        demand.network = true
        let showing = { (page: PanelTab, item: MenuBarItem) in (window && tab == page) || popover == item }
        demand.gpu = (window && [.overview, .system].contains(tab)) || summary.contains(.gpu) || showing(.gpu, .gpu)
        demand.disk = (window && [.overview, .system, .cleaner, .disk].contains(tab)) || summary.contains(.disk) || popover == .disk
        demand.diskDetail = showing(.disk, .disk)
        demand.battery = (window && [.overview, .system, .keepAwake].contains(tab)) || keepAwake.lidClosedActive
            || summary.contains(.battery) || showing(.battery, .battery)
        demand.processes = processPage || (window && [.overview, .disk].contains(tab)) || showing(.cpu, .cpu) || showing(.memory, .memory)
            || popover == .disk || (isCombinedOverviewVisible && showsOverviewProcesses)
        demand.systemProcesses = processPage

        var groups = Set<TemperatureGroup>()
        if window && tab == .overview { groups.formUnion([.cpu, .gpu]) }
        if overview.contains(.cpu) || overview.contains(.temperature) { groups.insert(.cpu) }
        if overview.contains(.gpu) { groups.insert(.gpu) }
        if (window && tab == .thermal) || thermalPopover { groups.formUnion(TemperatureGroup.allCases) }
        if menu.contains(.temperature) || fans.mode != .automatic || showing(.cpu, .cpu) { groups.insert(.cpu) }
        if showing(.gpu, .gpu) { groups.insert(.gpu) }
        if showing(.battery, .battery) { groups.insert(.battery) }
        if settings.enabledAlerts.contains(.cpuTemperature) { groups.insert(.cpu) }
        demand.temperatures = groups
        demand.power = (window && tab == .thermal) || thermalPopover || showing(.battery, .battery)
        demand.cpuFrequency = showing(.cpu, .cpu)
        // 未知时隐藏入口，但保留按需探测；不能用界面可见性阻断首次识别或失败重试。
        demand.fans = store.fanCount != 0 && ((window && (tab == .thermal || tab == .overview)) || summary.contains(.fan)
            || fans.mode != .automatic || thermalPopover
            || (store.fanCount == nil && settings.menuBarItems.contains(.fan)
                && (settings.menuBarLayout != .iconOnly || isCombinedOverviewVisible)))
        return demand
    }

    /// 蓝牙电量读取很慢，只在需要时轮询：电池弹窗 / 页面、本机信息页打开时每分钟；
    /// 菜单栏开着电池项且要做低电量提示、或这台 Mac 没有电池时每 5 分钟
    var bluetoothDemand: BluetoothController.Demand {
        if (isMainWindowVisible && [.battery, .system].contains(settings.panelTab)) || openPopover == .battery { return .foreground }
        if isCombinedOverviewVisible && visibleMenuBarItems.contains(.battery) && store.battery == nil { return .foreground }
        if drawnMenuBarItems.contains(.battery) && (settings.bluetoothLowBatteryInMenuBar || store.battery == nil) { return .background }
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
        guard store.supportsFans else { return }
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

    /// 进程快捷键始终可用；关闭内置模块时交给系统应用，不隐式开启模块。
    func openProcessMonitor() {
        if settings.processesEnabled { openMainWindow(.processes) }
        else { openActivityMonitor() }
    }

    /// 用 Apple 智能解释进程：结果显示在主窗口的进程页
    func explainProcess(_ subject: ProcessExplainer.Subject) {
        guard settings.processesEnabled else { return }
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
