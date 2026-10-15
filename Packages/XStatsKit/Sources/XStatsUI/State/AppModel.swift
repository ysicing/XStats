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
    let wellness: WellnessController
    let calendarAgenda = CalendarAgendaController()
    public let aiUsage: AIUsageController
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
    let appManagement = AppManagementController(cacheURL: AppInventoryCache.defaultURL)
    public let bluetooth = BluetoothController()
    let sleepAssertions = SleepAssertionController()
    let startupItems = StartupItemsController()
    public let history: HistoryRecorder
    public let sync: SyncController
    let diskTools: DiskToolsController
    @ObservationIgnored public let hub = MetricsHub()
    @ObservationIgnored private var restoringFans: Task<Void, Never>?

    /// 功能页分类仅用于当前窗口，不持久化、不影响采样需求。
    var featureSettingsTab: FeatureSettingsTab = .basic

    /// 只为当前可见的灵动岛场景申请已有采样，不启动独立采集器。
    var islandScene: IslandScene?
    var islandExpanded = false

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
    @ObservationIgnored var previewIsland: () -> Void = {}
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

    public convenience init(settings: AppSettings = AppSettings(), historyURL: URL? = HistoryDatabase.defaultURL,
                            aiUsageProviders: [any AIUsageProvider]? = nil,
                            aiQuotaProviders: [any AIQuotaProvider]? = nil,
                            quotaCacheURL: URL? = nil, magpieClient: (any MagpieFetching)? = nil,
                            networkCacheDefaults: UserDefaults = .standard) {
        self.init(settings: settings, historyURL: historyURL, aiUsageProviders: aiUsageProviders,
                  aiQuotaProviders: aiQuotaProviders, quotaCacheURL: quotaCacheURL, magpieClient: magpieClient,
                  networkCacheDefaults: networkCacheDefaults, fanControl: nil)
    }

    /// 测试可替换风扇特权调用，验证手动档位下的安全采样需求；nil 使用辅助工具。
    init(settings: AppSettings, historyURL: URL?, aiUsageProviders: [any AIUsageProvider]?,
         aiQuotaProviders: [any AIQuotaProvider]?, quotaCacheURL: URL?, magpieClient: (any MagpieFetching)?,
         networkCacheDefaults: UserDefaults, fanControl: (any FanControlClient)?) {
        let store = MetricsStore()
        let helper = HelperClient()
        self.settings = settings
        uninstaller = UninstallerController(enabled: settings.uninstallerEnabled)
        let observationBackend = NativeNetworkMonitorBackend()
        connectionMonitor = NetworkMonitorController(backend: observationBackend, defaults: settings.networkObservationDefaults)
        networkComponent = NetworkComponentController(backend: observationBackend)
        audio = AudioController(defaults: settings.audioDefaults)
        rest = RestController(settings: settings)
        wellness = WellnessController(rest: rest, settings: settings, store: WellnessActivityStore(url: settings.wellnessStorageURL))
        // 显式注入的测试或截图来源不受开发机已安装应用影响。
        let magpie = magpieClient ?? (aiUsageProviders == nil && aiQuotaProviders == nil ? MagpieInstallation.client() : nil)
        aiUsage = AIUsageController(settings: settings,
            providers: aiUsageProviders ?? (magpie == nil ? [CodexLocalUsageProvider(), ClaudeLocalUsageProvider()] : []),
            quotaProviders: aiQuotaProviders ?? (magpie == nil ? [CodexQuotaProvider(), ClaudeQuotaProvider()] : []),
            quotaCacheURL: quotaCacheURL, costReferenceStore: .shared, magpieClient: magpie)
        self.store = store
        self.helper = helper
        let samplingHub = hub
        fans = FanController(helper: fanControl ?? helper, store: store, settings: settings,
                             readFans: { await samplingHub.sampleFans() })
        keepAwake = KeepAwakeController(helper: helper, settings: settings)
        cleaner = CleanerController(settings: settings)
        projectPurge = ProjectPurgeController(settings: settings)
        maintenance = MaintenanceController(helper: helper)
        network = NetworkController(settings: settings, cacheDefaults: networkCacheDefaults)
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
        detectFanHardware()
    }

    /// 风扇数量原本只随传感器采样识别；能耗与风扇都关闭时不再采样，未知数量会隐藏风扇开关和入口，
    /// 用户无法重新开启。启动时在 Hub actor 上只读一次 FNum，不新增轮询，结果由传感器采样器复用。
    private func detectFanHardware() {
        guard store.fanCount == nil else { return }
        let hub = hub
        Task { [weak self] in
            let count = await hub.detectFanCount()
            self?.store.recordFanCount(count)
        }
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

    var fanFeedbackVisible: Bool {
        settings.isModuleEnabled(.thermal) && store.supportsFans
            && (drawnMenuBarItems.contains(.fan) || openPopover == .fan
                || (isCombinedOverviewVisible && visibleMenuBarItems.contains(.fan))
                || (isMainWindowVisible && [.overview, .thermal].contains(settings.panelTab)))
    }

    /// 根据当前可见内容决定采集范围：主窗口看标签页，详情弹窗看是哪一项
    var demand: MetricsDemand {
        var demand = MetricsDemand()
        demand.generation = settings.monitoringGeneration
        let tab = settings.panelTab
        let window = isMainWindowVisible && (tab == .battery || (tab.monitoringModule.map(settings.isModuleEnabled) ?? true))
        let energyEnabled = settings.isModuleEnabled(.battery)
        let processPage = settings.processesEnabled && window && tab == .processes
        let popover = openPopover.flatMap { settings.isModuleEnabled(for: $0) ? $0 : nil }
        let menu = Set(drawnMenuBarItems)
        let overview = isCombinedOverviewVisible ? Set(visibleMenuBarItems) : []
        let summary = menu.union(overview)
        let temperaturePopover = popover == .temperature
        let fanPopover = popover == .fan
        let islandSystem = islandScene == .system
        let islandDetails = islandSystem && islandExpanded
        let liveIsland = islandSystem && (settings.isModuleEnabled(.cpu)
            || (islandDetails && (settings.isModuleEnabled(.memory) || energyEnabled)))

        // 仅实时监控页需要每秒采样；历史、工具和设置页沿用用户设置的后台间隔。
        // 能耗关闭时能耗页只展示基础电量，不算实时页，交给下方 10 秒基础电量分支。
        let liveWindow = window && ([.overview, .system, .cpu, .gpu, .memory, .disk,
                                     .network, .thermal].contains(tab) || (tab == .battery && energyEnabled))
        // AI 用量与显示器有各自的刷新机制，不读取采样结果，不应提高全局采样频率。
        let selfRefreshing: Set<MenuBarItem> = [.aiUsage, .display, .audio]
        let livePopover = popover.map { !selfRefreshing.contains($0) } ?? false
        // 合并面板的摘要始终可见；只有其中的系统指标需要提高全局采样频率。
        let liveOverview = !overview.subtracting(selfRefreshing).isEmpty
        // 进程页要读全系统进程（启动 ps），每 2 秒刷新一次足够，也更省电
        demand.interval = processPage && !livePopover ? .seconds(2)
            : liveWindow || livePopover || liveOverview || liveIsland ? .seconds(1) : .seconds(settings.refreshSeconds)
        let dashboard = window && tab == .overview
        let recording = settings.historyEnabled
        let alerts = settings.activeAlerts
        let showing = { (page: PanelTab, item: MenuBarItem) in (window && tab == page) || popover == item }
        demand.cpu = settings.isModuleEnabled(.cpu)
            && (islandSystem || recording || dashboard || processPage || summary.contains(.cpu) || showing(.cpu, .cpu) || alerts.contains(.cpuLoad))
        demand.memory = settings.isModuleEnabled(.memory)
            && (islandDetails || recording || dashboard || summary.contains(.memory) || showing(.memory, .memory) || alerts.contains(.memoryPressure))
        demand.network = settings.isModuleEnabled(.network)
            && (recording || dashboard || summary.contains(.network) || showing(.network, .network))
        demand.gpu = (window && [.overview, .system].contains(tab)) || summary.contains(.gpu) || showing(.gpu, .gpu)
        demand.disk = (window && [.overview, .system, .cleaner, .disk].contains(tab)) || summary.contains(.disk) || popover == .disk
        demand.diskDetail = showing(.disk, .disk)
        demand.battery = (window && [.overview, .system, .keepAwake].contains(tab)) || keepAwake.lidClosedActive
            || summary.contains(.battery) || showing(.battery, .battery)
        demand.processes = processPage || (window && [.overview, .disk].contains(tab)) || showing(.cpu, .cpu) || showing(.memory, .memory)
            || popover == .disk
        demand.systemProcesses = processPage

        var groups = Set<TemperatureGroup>()
        if islandDetails { groups.insert(.cpu) }
        if window && tab == .overview { groups.formUnion([.cpu, .gpu]) }
        if overview.contains(.cpu) || overview.contains(.temperature) { groups.insert(.cpu) }
        if overview.contains(.gpu) { groups.insert(.gpu) }
        if (window && tab == .battery) || (temperaturePopover && settings.isVisible(.thermalSensors))
            || (popover == .battery && settings.isVisible(.thermalSensors)) { groups.formUnion(TemperatureGroup.allCases) }
        if menu.contains(.temperature) || temperaturePopover || fans.mode != .automatic || showing(.cpu, .cpu) { groups.insert(.cpu) }
        if showing(.gpu, .gpu) { groups.insert(.gpu) }
        if settings.isModuleEnabled(.battery), showing(.battery, .battery) { groups.insert(.battery) }
        if alerts.contains(.cpuTemperature) { groups.insert(.cpu) }
        demand.temperatures = groups
        demand.power = settings.isModuleEnabled(.battery)
            && (islandDetails || (window && tab == .battery)
                || (temperaturePopover && settings.isVisible(.thermalPower))
                || (popover == .battery && settings.isVisible(.batteryPower)))
        let gpuDetailsVisible = (window && tab == .gpu) || (popover == .gpu && settings.isVisible(.gpuDetails))
        demand.gpuFrequency = settings.isModuleEnabled(.gpu) && gpuDetailsVisible
        demand.gpuPower = energyEnabled && demand.gpuFrequency
        demand.cpuFrequency = showing(.cpu, .cpu)
        // 未知时隐藏入口，但保留按需探测；不能用界面可见性阻断首次识别或失败重试。
        demand.fans = store.fanCount != 0 && ((window && (tab == .thermal || tab == .overview)) || summary.contains(.fan)
            || fans.mode != .automatic || fanPopover
            || (store.fanCount == nil && settings.menuBarItems.contains(.fan)
                && (settings.menuBarLayout != .iconOnly || isCombinedOverviewVisible)))
        demand.gpu = demand.gpu && settings.isModuleEnabled(.gpu)
        demand.disk = demand.disk && settings.isModuleEnabled(.disk)
        demand.diskDetail = demand.diskDetail && settings.isModuleEnabled(.disk)
        demand.cpuFrequency = demand.cpuFrequency && settings.isModuleEnabled(.cpu)
        if !settings.isModuleEnabled(.battery) { demand.temperatures = [] }
        if !settings.isModuleEnabled(.thermal) { demand.fans = false }
        // 能耗与温度不依赖内置电池；只有可见的 App 能耗分区才读取进程计数。
        demand.appEnergy = settings.isModuleEnabled(.battery)
            && ((window && tab == .battery) || (popover == .battery && settings.isVisible(.batteryApps)))
        // 风扇交还系统和合盖电量保护仍须完成，不能由隐藏监控界面切断安全需求。
        if fans.mode != .automatic || fans.isApplying || restoringFans != nil {
            demand.temperatures.insert(.cpu)
            demand.fans = true
        }
        if keepAwake.lidClosedActive { demand.battery = true }
        demand.processes = processPage || (demand.processes && (
            dashboard && (settings.isModuleEnabled(.cpu) || settings.isModuleEnabled(.memory))
            || showing(.cpu, .cpu) || showing(.memory, .memory)
            || demand.diskDetail))
        // 基础电量每 10 秒读取一次；只有这个读取方时无需维持秒级唤醒。
        if !settings.isModuleEnabled(.battery), demand.battery {
            var otherDemand = demand
            otherDemand.battery = false
            if !otherDemand.hasSamples { demand.interval = .seconds(10) }
        }
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

    var sleepAssertionsVisible: Bool {
        settings.isModuleEnabled(.battery) && isMainWindowVisible && settings.panelTab == .battery
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

    /// 普通防休眠快捷入口不隐式开启已保存的合盖运行请求。
    func requestKeepAwake(_ active: Bool, duration: KeepAwakeController.Duration? = nil) {
        if active, keepAwake.lidClosedRequested || keepAwake.lidClosedActive {
            openMainWindow(.keepAwake)
            return
        }
        if let duration { keepAwake.setDuration(duration) }
        Task { await keepAwake.setActive(active) }
    }

    /// 快捷切换风扇：缺少参数或辅助工具时打开散热页，按需采样并引导操作。
    func requestFanMode(_ mode: FanController.Mode) {
        guard mode == .automatic || settings.isModuleEnabled(.thermal) else {
            settings.panelTab = .thermal
            if !isMainWindowVisible { openMainWindow(.thermal) }
            return
        }
        guard store.supportsFans else { return }
        if mode != .automatic, store.sensors?.fans.isEmpty != false {
            settings.panelTab = .thermal
            if !isMainWindowVisible { openMainWindow(.thermal) }
            return
        }
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
        // 每个快照只计算一次需求；裁剪与清理期间不改变功耗和 App 能耗的读取方。
        let demand = demand
        // actor 已采完的快照可能晚于开关关闭到达；在主线程再次按最终开关裁剪。
        let filtered = snapshotForEnabledModules(snapshot, demand: demand)
        store.clearDisabledModules(settings.enabledMonitoringModules, powerRequested: demand.power, gpuPowerRequested: demand.gpuPower,
                                   gpuFrequencyRequested: demand.gpuFrequency, appEnergyRequested: demand.appEnergy)
        store.apply(filtered)
        fans.evaluateSafety(temperature: snapshot.sensors?.temperature(.cpu)?.maximum)
        keepAwake.evaluateBattery(snapshot.battery)
        alerts.evaluate(store)
        history.record(filtered)
    }

    func snapshotForEnabledModules(_ snapshot: MetricsSnapshot, demand: MetricsDemand? = nil) -> MetricsSnapshot {
        let demand = demand ?? self.demand
        var result = snapshot
        if !demand.appEnergy { result.appEnergy = nil }
        if !settings.isModuleEnabled(.cpu) { result.cpu = nil; result.power?.clusterFrequency = [:] }
        if !settings.isModuleEnabled(.memory) { result.memory = nil }
        if !settings.isModuleEnabled(.network) { result.network = nil; result.networkInterface = nil }
        if !settings.isModuleEnabled(.gpu) { result.gpu = nil }
        if !settings.isModuleEnabled(.disk) { result.disk = nil; result.diskActivity = nil; result.diskHealth = nil }
        if let sensors = result.sensors {
            let energyEnabled = settings.isModuleEnabled(.battery)
            let fansEnabled = settings.isModuleEnabled(.thermal)
            // 硬件数量随既有传感器采样识别，关闭风扇采集仍保留能力判断。
            result.sensors = energyEnabled || fansEnabled
                ? SensorReadings(temperatures: energyEnabled ? sensors.temperatures : [],
                                 fans: fansEnabled ? sensors.fans : [],
                                 fanCount: sensors.fanCount) : nil
        }
        result.power = result.power?.retaining(system: demand.power, gpu: demand.power || demand.gpuPower,
                                              cpuFrequency: settings.isModuleEnabled(.cpu),
                                              gpuFrequency: demand.gpuFrequency)
        return result
    }

    /// 开关变化后同步清理已停止更新的实时值；旧历史数据库不受影响。
    func applyMonitoringSettings() {
        uninstaller.setEnabled(settings.uninstallerEnabled)
        appManagement.setEnabled(settings.uninstallerEnabled)
        displays.setEnabled(settings.isModuleEnabled(.display))
        store.clearDisabledModules(settings.enabledMonitoringModules, powerRequested: demand.power, gpuPowerRequested: demand.gpuPower,
                                   gpuFrequencyRequested: demand.gpuFrequency, appEnergyRequested: demand.appEnergy)
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
