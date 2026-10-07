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
    let connectionMonitor: NetworkMonitorController
    let networkComponent: NetworkComponentController
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
    public let uninstaller: UninstallerController
    public let bluetooth = BluetoothController()
    let startupItems = StartupItemsController()
    public let history: HistoryRecorder
    public let sync: SyncController
    let diskTools: DiskToolsController
    @ObservationIgnored public let hub = MetricsHub()
    @ObservationIgnored private var restoringFans: Task<Void, Never>?

    /// 功能页分类仅用于当前窗口，不持久化、不影响采样需求。
    var featureSettingsTab: FeatureSettingsTab = .basic

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
        let store = MetricsStore(readBattery: settings.isModuleEnabled(.battery))
        let helper = HelperClient()
        self.settings = settings
        uninstaller = UninstallerController(enabled: settings.uninstallerEnabled)
        let observationBackend = NativeNetworkMonitorBackend()
        connectionMonitor = NetworkMonitorController(backend: observationBackend, defaults: settings.networkObservationDefaults)
        networkComponent = NetworkComponentController(backend: observationBackend)
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
        updates = UpdateController(settings: settings, defaults: settings.updateDefaults)
        alerts = AlertController(settings: settings)
        history = HistoryRecorder(settings: settings, databaseURL: historyURL)
        sync = SyncController(settings: settings)
        diskTools = DiskToolsController(helper: helper)
        speedTest = SpeedTestController(settings: settings)
        updates.prepareForInstallation = { [weak self] in self?.connectionMonitor.prepareForAppUpdate() }
        networkComponent.onPreparingUpdate = { [weak self] in self?.connectionMonitor.beginComponentUpdate() }
        networkComponent.onUpdateFinished = { [weak self] in self?.connectionMonitor.finishComponentUpdate() }
        networkComponent.onUninstalled = { [weak self] in self?.settings.networkConnectionsEnabled = false }
        updates.onCheckCompleted = { [weak self] in self?.networkComponent.checkUpdates(background: true) }
        updates.cancelInstallationPreparation = { [weak self] in self?.connectionMonitor.cancelAppUpdate() }

    }

    /// 安装面板回调与设置开关共用启用入口；先同步需求，避免偏好观察尚未调度时 start 被拒绝。
    func enableNetworkObservation() {
        settings.networkConnectionsEnabled = true
        connectionMonitor.setDemand(enabled: settings.canViewNetworkConnections,
                                    visible: isMainWindowVisible && settings.panelTab == .connections)
        connectionMonitor.start()
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
        settings.isModuleEnabled(.display)
            && (openPopover == .display || (isMainWindowVisible && settings.panelTab == .system))
    }

    /// 根据当前可见内容决定采集范围：主窗口看标签页，详情弹窗看是哪一项
    var demand: MetricsDemand {
        var demand = MetricsDemand()
        demand.generation = settings.monitoringGeneration
        let tab = settings.panelTab
        let window = isMainWindowVisible && (tab.monitoringModule.map(settings.isModuleEnabled) ?? true)
        let processPage = settings.processesEnabled && window && tab == .processes
        let popover = openPopover.flatMap { settings.isModuleEnabled(for: $0) ? $0 : nil }
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
        let dashboard = window && tab == .overview
        let recording = settings.historyEnabled
        let alerts = settings.activeAlerts
        let showing = { (page: PanelTab, item: MenuBarItem) in (window && tab == page) || popover == item }
        demand.cpu = settings.isModuleEnabled(.cpu)
            && (recording || dashboard || processPage || summary.contains(.cpu) || showing(.cpu, .cpu) || alerts.contains(.cpuLoad))
        demand.memory = settings.isModuleEnabled(.memory)
            && (recording || dashboard || summary.contains(.memory) || showing(.memory, .memory) || alerts.contains(.memoryPressure))
        demand.network = settings.isModuleEnabled(.network)
            && (recording || dashboard || summary.contains(.network) || showing(.network, .network))
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
        if alerts.contains(.cpuTemperature) { groups.insert(.cpu) }
        demand.temperatures = groups
        demand.power = (window && tab == .thermal) || thermalPopover || showing(.battery, .battery)
        demand.cpuFrequency = showing(.cpu, .cpu)
        // 未知时隐藏入口，但保留按需探测；不能用界面可见性阻断首次识别或失败重试。
        demand.fans = store.fanCount != 0 && ((window && (tab == .thermal || tab == .overview)) || summary.contains(.fan)
            || fans.mode != .automatic || thermalPopover
            || (store.fanCount == nil && settings.menuBarItems.contains(.fan)
                && (settings.menuBarLayout != .iconOnly || isCombinedOverviewVisible)))
        demand.gpu = demand.gpu && settings.isModuleEnabled(.gpu)
        demand.disk = demand.disk && settings.isModuleEnabled(.disk)
        demand.diskDetail = demand.diskDetail && settings.isModuleEnabled(.disk)
        demand.battery = demand.battery && (settings.isModuleEnabled(.battery) || keepAwake.lidClosedActive)
        demand.cpuFrequency = demand.cpuFrequency && settings.isModuleEnabled(.cpu)
        if !settings.isModuleEnabled(.thermal) {
            demand.temperatures = []
            demand.fans = false
            demand.power = false
        }
        // 风扇交还系统和合盖电量保护仍须完成，不能由隐藏监控界面切断安全需求。
        if fans.mode != .automatic || fans.isApplying || restoringFans != nil {
            demand.temperatures.insert(.cpu)
            demand.fans = true
        }
        if keepAwake.lidClosedActive { demand.battery = true }
        demand.processes = processPage || (demand.processes && (
            dashboard && (settings.isModuleEnabled(.cpu) || settings.isModuleEnabled(.memory))
            || showing(.cpu, .cpu) || showing(.memory, .memory)
            || demand.diskDetail || isCombinedOverviewVisible && showsOverviewProcesses))
        return demand
    }

    /// 蓝牙电量读取很慢，只在需要时轮询：电池弹窗 / 页面、本机信息页打开时每分钟；
    /// 菜单栏开着电池项且要做低电量提示、或这台 Mac 没有电池时每 5 分钟
    var bluetoothDemand: BluetoothController.Demand {
        guard settings.isModuleEnabled(.battery) else { return .off }
        if (isMainWindowVisible && [.battery, .system].contains(settings.panelTab)) || openPopover == .battery { return .foreground }
        if isCombinedOverviewVisible && visibleMenuBarItems.contains(.battery) && store.battery == nil { return .foreground }
        if drawnMenuBarItems.contains(.battery) && (settings.bluetoothLowBatteryInMenuBar || store.battery == nil) { return .background }
        return .off
    }

    /// 网络详情（接口、公网 IP、进程流量）正在显示
    var isNetworkDetailVisible: Bool {
        settings.isModuleEnabled(.network)
            && (openPopover == .network || (isMainWindowVisible && settings.panelTab == .network))
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
        guard mode == .automatic || settings.isModuleEnabled(.thermal) else {
            settings.panelTab = .thermal
            if !isMainWindowVisible { openMainWindow(.thermal) }
            return
        }
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
        guard snapshot.samplingGeneration.map({ $0 == settings.monitoringGeneration }) ?? true else { return }
        // actor 已采完的快照可能晚于开关关闭到达；在主线程再次按最终开关裁剪。
        let filtered = snapshotForEnabledModules(snapshot)
        store.clearDisabledModules(settings.enabledMonitoringModules)
        store.apply(filtered)
        fans.evaluateSafety(temperature: snapshot.sensors?.temperature(.cpu)?.maximum)
        keepAwake.evaluateBattery(snapshot.battery)
        alerts.evaluate(store)
        history.record(filtered)
    }

    func snapshotForEnabledModules(_ snapshot: MetricsSnapshot) -> MetricsSnapshot {
        var result = snapshot
        if !settings.isModuleEnabled(.cpu) { result.cpu = nil; result.power?.clusterFrequency = [:] }
        if !settings.isModuleEnabled(.memory) { result.memory = nil }
        if !settings.isModuleEnabled(.network) { result.network = nil; result.networkInterface = nil }
        if !settings.isModuleEnabled(.gpu) { result.gpu = nil }
        if !settings.isModuleEnabled(.disk) { result.disk = nil; result.diskActivity = nil; result.diskHealth = nil }
        if !settings.isModuleEnabled(.battery) { result.battery = nil }
        if !settings.isModuleEnabled(.thermal) {
            result.sensors = nil
            result.power = settings.isModuleEnabled(.cpu) && result.power?.clusterFrequency.isEmpty == false
                ? PowerReading(clusterFrequency: result.power?.clusterFrequency ?? [:]) : nil
        }
        return result
    }

    /// 开关变化后同步清理已停止更新的实时值；旧历史数据库不受影响。
    func applyMonitoringSettings() {
        uninstaller.setEnabled(settings.uninstallerEnabled)
        displays.setEnabled(settings.isModuleEnabled(.display))
        store.clearDisabledModules(settings.enabledMonitoringModules)
        if let popover = openPopover, !settings.isModuleEnabled(for: popover) { openPopover = nil }
        if !settings.isModuleEnabled(.thermal), fans.mode != .automatic, !fans.isApplying, restoringFans == nil {
            restoringFans = Task { [weak self] in
                guard let self else { return }
                defer { self.restoringFans = nil }
                guard !self.settings.isModuleEnabled(.thermal) else { return }
                await self.fans.select(.automatic)
                // 交还系统失败时保留安全监控和控制入口，让用户能够处理错误。
                if self.fans.mode != .automatic { self.settings.setModuleEnabled(.thermal, true) }
            }
        }
    }
}
