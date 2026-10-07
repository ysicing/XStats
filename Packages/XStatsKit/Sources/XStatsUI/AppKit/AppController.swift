// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import AIUsage
import Localization
import Metrics
import SwiftUI
import WidgetData
import WidgetKit

@MainActor
public final class AppController: NSObject, NSApplicationDelegate {
    private let model = AppModel(quotaCacheURL: AIQuotaCacheStore.defaultURL)
    private let widgetStore = WidgetSnapshotStore()
    private var menuBar: MenuBarController!
    private var calendarMenuBar: CalendarMenuBarController!
    private var mainWindow: MainWindowController!
    private var aiUsageSettingsWindow: AIUsageSettingsWindowController!
    private var updateWindow: UpdateWindowController!
    private var speedTestWindow: SpeedTestWindowController!
    private var projectPurgeWindow: ProjectPurgeWindowController!
    private var egressWindow: EgressWindowController!
    private var rest: RestController { model.rest }
    private var restWindows: RestWindowController!
    private var restMenuBar: RestMenuBarController!
    private var widgetTimer: Timer?
    private let hotKeys = HotKeyCenter()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenLocked = false
    private var deepLinksReady = false
    private var pendingDeepLinks: [AppDeepLink] = []
    private var deepLinkTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = DiagnosticsExporter.launchDate
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? tr("开发版")
        Log.app.notice("XStats \(version, privacy: .public) 启动，macOS \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")
        NSApp.mainMenu = MainMenu.make(target: self, settingsAction: #selector(openSettingsFromMenu),
                                       updateAction: #selector(checkForUpdatesFromMenu))
        menuBar = MenuBarController(model: model)
        calendarMenuBar = CalendarMenuBarController(model: model)
        mainWindow = MainWindowController(model: model)
        mainWindow.onVisibilityChange = { [weak self] _ in self?.updateActivationPolicy() }
        aiUsageSettingsWindow = AIUsageSettingsWindowController(model: model)
        aiUsageSettingsWindow.onVisibilityChange = { [weak self] _ in self?.updateActivationPolicy() }
        updateWindow = UpdateWindowController(model: model)
        speedTestWindow = SpeedTestWindowController(model: model)
        speedTestWindow.onVisibilityChange = { [weak self] _ in self?.updateActivationPolicy() }
        projectPurgeWindow = ProjectPurgeWindowController(model: model)
        projectPurgeWindow.onVisibilityChange = { [weak self] _ in self?.updateActivationPolicy() }
        egressWindow = EgressWindowController(model: model)
        egressWindow.onVisibilityChange = { [weak self] _ in self?.updateActivationPolicy() }
        restWindows = RestWindowController(rest: rest)
        restMenuBar = RestMenuBarController(rest: rest, open: { [weak self] in
            self?.model.openMainWindow(.rest)
        }, toggleHUD: { [weak self] in
            self?.restWindows.toggleHUD()
        })
        rest.onRestChange = { [weak self] active in
            if active { self?.restWindows.showRest() } else { self?.restWindows.hideRest() }
        }
        rest.onStateChange = { [weak self] in self?.restMenuBar.update() }
        model.collapseToRestHUD = { [weak self] in
            self?.restWindows.showHUD()
            self?.mainWindow.close()
        }
        model.displays.setEnabled(model.settings.isModuleEnabled(.display))
        model.displays.start()
        model.audio.setDemand(enabled: model.settings.audioEnabled, visible: model.audioControlsVisible, menuVisible: model.audioMenuVisible)
        model.connectionMonitor.setDemand(enabled: model.settings.canViewNetworkConnections,
                                          visible: model.isMainWindowVisible && model.settings.panelTab == .connections)
        model.connectionMonitor.resumeAfterUpdate()
        menuBar.update()
        calendarMenuBar.start()

        // 设置已并入主窗口：所有“设置…”入口都打开主窗口的通用设置
        model.openSettings = { [weak self] in
            self?.menuBar.dismissPopovers()
            self?.calendarMenuBar.dismiss()
            self?.mainWindow.show(tab: .settingsGeneral)
        }
        model.openMainWindow = { [weak self] tab in
            self?.menuBar.dismissPopovers()
            self?.calendarMenuBar.dismiss()
            self?.mainWindow.show(tab: tab)
        }
        model.openAIUsageSettings = { [weak self] in
            self?.menuBar.dismissPopovers()
            self?.calendarMenuBar.dismiss()
            self?.aiUsageSettingsWindow.show()
        }
        model.openEgressWindow = { [weak self] in
            self?.menuBar.dismissPopovers()
            self?.calendarMenuBar.dismiss()
            self?.egressWindow.show()
        }
        model.openSpeedTestWindow = { [weak self] in
            self?.menuBar.dismissPopovers()
            self?.calendarMenuBar.dismiss()
            self?.speedTestWindow.show()
        }
        model.openProjectPurgeWindow = { [weak self] in
            guard let self, self.model.settings.cleanerEnabled else { return }
            self.menuBar.dismissPopovers()
            self.calendarMenuBar.dismiss()
            self.projectPurgeWindow.show()
        }
        model.quit = { NSApp.terminate(nil) }
        model.helper.refreshStatus()
        Task { await model.helper.verifyVersion() }
        model.helper.onReconnect = { [weak self] in
            Task { [weak self] in
                await self?.model.fans.reapply()
                await self?.model.keepAwake.reapply()
            }
        }

        observeWorkspace()
        observeRestSettings()
        observeCleanerSetting()
        observeRestMode()
        observeRestSound()
        rest.sync()
        restMenuBar.sync()
        observeModel()
        observeNetworkObservationDemand()
        observeProbeSettings()
        observeAIUsageSchedule()
        observeAIUsageState()
        observeWidgetState()
        syncWidgetSnapshot()
        widgetTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncWidgetSnapshot()
            }
        }
        widgetTimer?.tolerance = 5 * 60
        model.aiUsage.start()
        applyAppearance()
        updateNetworkVisibility()
        appliedLanguage = model.settings.language
        startUpdateChecks()
        model.alerts.openTab = { [weak self] tab in
            self?.menuBar.dismissPopovers()
            self?.calendarMenuBar.dismiss()
            self?.mainWindow.show(tab: tab)
        }
        model.alerts.start()
        hotKeys.onAction = { [weak self] action in self?.perform(action) }
        applyHotKeys()

        // 开发调试：--show-panel [overview|cpu|memory|network|gpu|disk|temperature|fan|battery|aiUsage] 启动后展开并固定弹窗
        // （overview 是合并模式的状态总览；合并模式下给某一项则打开面板并切到这一项）；--show-window 打开主窗口；
        // --show-egress 打开出口与分流窗口
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--show-panel") {
            let argument = arguments.dropFirst(index + 1).first
            let item = argument.flatMap(MenuBarItem.init(rawValue:)) ?? .network
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.menuBar.pinsNextPopover = true
                if argument == "overview" {
                    self?.menuBar.toggleOverview()
                } else {
                    self?.menuBar.togglePopover(item)
                }
            }
        }
        if arguments.contains("--show-calendar") {
            model.settings.calendarEnabled = true
            calendarMenuBar.update()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.calendarMenuBar.show()
            }
        }
        if arguments.contains("--show-window") {
            mainWindow.show(tab: nil)
        }
        if arguments.contains("--show-speedtest") {
            speedTestWindow.show()
        }
        // 开发调试：--probe <域名> 打开测速窗口并立即用全球探针 ping 这个域名
        if let index = arguments.firstIndex(of: "--probe"), let domain = arguments.dropFirst(index + 1).first {
            speedTestWindow.show()
            model.speedTest.globalpingTarget = domain
            model.speedTest.runGlobalping()
        }
        if arguments.contains("--show-egress") {
            egressWindow.show()
        }
        // 开发调试：--explain-process <进程名> 打开进程页并用 Apple 智能解释该进程
        if model.settings.processesEnabled, let index = arguments.firstIndex(of: "--explain-process"),
           let name = arguments.dropFirst(index + 1).first {
            mainWindow.show(tab: .processes)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self else { return }
                let processes = self.model.store.processes
                guard let process = processes.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) ?? processes.first else { return }
                self.model.explainProcess(.init(process))
            }
        }

        let appModel = model
        appModel.bluetooth.setDemand(appModel.bluetoothDemand)
        appModel.displays.setVisible(appModel.displayControlsVisible)
        Task { [weak self] in
            await appModel.hub.update(appModel.demand)
            await appModel.hub.start(primeAllMetrics: false) { [weak self] snapshot in
                appModel.handle(snapshot)
                self?.menuBar.refreshImages()
            }
        }
        deepLinksReady = true
        drainDeepLinks()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.updates.installationRequiresPreparation || model.connectionMonitor.terminationRequiresPreparation || model.networkComponent.terminationRequiresPreparation else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        // Sparkle 在安装就绪后可能因用户主动退出而继续安装；退出也必须经过相同的停用门禁。
        terminationTask = Task {
            defer { terminationTask = nil }
            do {
                let updatingApp = model.updates.installationRequiresPreparation
                if updatingApp { try await model.updates.prepareForTermination() }
                await model.networkComponent.prepareForTermination()
                try await model.connectionMonitor.prepareForTermination(preserveFilter: updatingApp)
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                model.networkComponent.cancelTermination()
                if model.updates.installationRequiresPreparation { model.updates.installationPreparationFailed(error) }
                else { model.connectionMonitor.noteTerminationFailure(error) }
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        deepLinksReady = false
        deepLinkTask?.cancel(); pendingDeepLinks.removeAll()
        Log.app.notice("XStats 自身即将退出，PID \(ProcessInfo.processInfo.processIdentifier)")
        rest.prepareForTermination()
        widgetTimer?.invalidate()
        calendarMenuBar.stop()
        model.displays.stop()
        model.audio.stop()
        model.connectionMonitor.shutdown()
        model.networkGeography.setDemand(enabled: false)
        model.aiUsage.stop()
        model.keepAwake.releaseForTermination()
        if model.fans.mode != .automatic || model.keepAwake.lidClosedActive {
            model.helper.restoreDefaultsSynchronously()
        }
    }

    /// 再次打开应用（访达或启动台）时显示主窗口
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.show(tab: nil) }
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        // 冷启动可能先收到 URL；最多保留 16 条已解析命令，不常驻保存外部原始 URL。
        for url in urls.prefix(16) {
            guard pendingDeepLinks.count < 16 else { break }
            if let link = AppDeepLink(url: url) { pendingDeepLinks.append(link) }
        }
        drainDeepLinks()
    }

    private func drainDeepLinks() {
        guard deepLinksReady, deepLinkTask == nil, !pendingDeepLinks.isEmpty else { return }
        deepLinkTask = Task { [weak self] in
            guard let self else { return }
            defer { deepLinkTask = nil }
            while !Task.isCancelled, deepLinksReady, !pendingDeepLinks.isEmpty {
                await performDeepLink(pendingDeepLinks.removeFirst())
            }
        }
    }

    private func performDeepLink(_ link: AppDeepLink) async {
        switch link {
        case .open(let requested):
            model.openMainWindow(requested.map { AppDeepLink.page($0, settings: model.settings) })
        case .panel(let item):
            if let item {
                guard model.visibleMenuBarItems.contains(item), menuBar.showPopover(item) else {
                    model.openMainWindow(AppDeepLink.page(PanelTab(item: item), settings: model.settings)); return
                }
            } else if !menuBar.showOverview() { model.openMainWindow(.overview) }
        case .calendar:
            if model.settings.calendarEnabled, calendarMenuBar.present() { return }
            else { model.openMainWindow(.settingsFeatures) }
        case .speedTest: model.openSpeedTestWindow()
        case .egress: model.openEgressWindow()
        case .rest(let action):
            guard model.settings.restEnabled else { model.openMainWindow(.settingsFeatures); return }
            switch action {
            case .start: rest.setRunning(true)
            case .pause: rest.setRunning(false)
            case .toggle: rest.startPause()
            case .reset: rest.resetCurrentPhase()
            case .skip: rest.skip()
            case .hud: model.collapseToRestHUD()
            }
        case .keepAwake(let action):
            // URL 可来自网页或其他应用；普通防休眠入口不得顺带下发合盖模式的特权设置。
            guard !model.keepAwake.lidClosedRequested, !model.keepAwake.lidClosedActive else {
                model.openMainWindow(.keepAwake); return
            }
            let active = action == .start || (action == .toggle && !model.keepAwake.isActive)
            if active != model.keepAwake.isActive { await model.keepAwake.setActive(active) }
        }
    }

    @objc private func openSettingsFromMenu() { model.openSettings() }

    @objc private func checkForUpdatesFromMenu() {
        model.updates.check(userInitiated: true)
        mainWindow.show(tab: .settingsAbout)
    }

    private func applyHotKeys() {
        hotKeys.apply(model.settings.hotKeys)
        model.hotKeyConflicts = hotKeys.conflicts
        withObservationTracking {
            _ = model.settings.hotKeys
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyHotKeys() }
        }
    }

    private func perform(_ action: HotKeyAction) {
        Log.app.info("快捷键：\(action.rawValue, privacy: .public)")
        switch action {
        case .toggleMainWindow:
            if mainWindow.isVisible && NSApp.isActive { mainWindow.close() } else { mainWindow.show(tab: nil) }
        case .showProcesses:
            menuBar.dismissPopovers()
            model.openProcessMonitor()
        case .toggleKeepAwake:
            Task { await model.keepAwake.setActive(!model.keepAwake.isActive) }
        case .purgeMemory:
            Task { await model.maintenance.run(.purgeMemory) }
        case .openCalendar:
            menuBar.dismissPopovers()
            model.openCalendar()
        }
    }

    /// 启动 10 秒后启动 Sparkle，由它统一安排后续检查。
    private func startUpdateChecks() {
        model.updates.onPrompt = { [weak self] in
            self?.menuBar.dismissPopovers()
            self?.calendarMenuBar.dismiss()
            self?.updateWindow.show()
        }
        model.updates.onUpdateAvailable = { [weak self] version in
            await self?.model.alerts.notifyUpdate(version: version) ?? false
        }
        model.alerts.openUpdates = { [weak self] in
            guard let self else { return }
            if self.model.updates.release != nil {
                self.model.updates.onPrompt()
            } else {
                // 通知可跨应用重启保留；重新检查后展示当前有效的更新信息。
                self.checkForUpdatesFromMenu()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.model.updates.start()
        }
    }

    /// 默认只在菜单栏运行、不占程序坞；打开了“在程序坞显示图标”时，有窗口开着才出现在程序坞与 ⌘Tab 里
    private func updateActivationPolicy() {
        let hasWindow = mainWindow.isVisible || aiUsageSettingsWindow.isVisible
            || egressWindow.isVisible || speedTestWindow.isVisible || projectPurgeWindow.isVisible
        let policy: NSApplication.ActivationPolicy = hasWindow && model.settings.showDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if hasWindow { NSApp.activate() }
    }

    // MARK: 观察

    /// 设置或可见内容变化时，更新采样范围、网络探测并重绘菜单栏
    private func observeModel() {
        withObservationTracking {
            _ = model.demand
            _ = model.bluetoothDemand
            _ = model.displayControlsVisible
            _ = model.settings.audioEnabled
            _ = model.audioControlsVisible
            _ = model.audioMenuVisible
            _ = model.audio.output
            _ = model.displays.catalog
            _ = model.settings.menuBarItems
            _ = model.settings.menuBarLayout
            _ = model.settings.menuBarStyle
            _ = model.settings.networkStyle
            _ = model.settings.processesEnabled
            _ = model.settings.uninstallerEnabled
            _ = model.settings.networkLocationStyle
            _ = model.settings.publicIPLookup
            _ = model.network.publicAddresses?.countryCode
            _ = model.settings.styleOverrides
            _ = model.settings.colorizeHighLoad
            _ = model.settings.useFahrenheit
            _ = model.settings.hiddenPopoverSections
            _ = model.settings.expandedPopoverSections
            _ = model.keepAwake.isActive
            _ = model.settings.appearance
            _ = model.settings.showDockIcon
            _ = model.isNetworkDetailVisible
            _ = model.settings.probeEnabled
            _ = model.settings.probeInBackground
            _ = model.settings.enabledAlerts
            _ = model.settings.historyEnabled
            _ = model.settings.enabledMonitoringModules
            _ = model.fans.isApplying
            _ = model.settings.language
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // 一次性订阅先恢复，再做任何修改或 await，避免漏掉关闭或特权复位的完成/失败。
                self.observeModel()
                self.applyLanguageIfChanged()
                self.model.applyMonitoringSettings()
                if !self.model.settings.processesEnabled { self.model.explainer.dismiss() }
                self.model.alerts.applySettings()
                await self.model.hub.update(self.model.demand)
                self.model.bluetooth.setDemand(self.model.bluetoothDemand)
                self.model.displays.setVisible(self.model.displayControlsVisible)
                self.model.audio.setDemand(enabled: self.model.settings.audioEnabled, visible: self.model.audioControlsVisible, menuVisible: self.model.audioMenuVisible)
                self.applyAppearance()
                self.updateActivationPolicy()
                self.menuBar.update()
                self.menuBar.refreshPopoverHeight()
                self.updateNetworkVisibility()
            }
        }
    }

    /// 网络观察的订阅单独闭环，不跨其它采样模块的 await，避免漏掉等待期间的关闭/暂停。
    private func observeNetworkObservationDemand() {
        withObservationTracking {
            _ = model.settings.canViewNetworkConnections
            _ = model.settings.panelTab
            _ = model.isMainWindowVisible
            _ = model.connectionMonitor.isReading
        } onChange: { [weak self] in
            // Observation 在 willSet 阶段通知；下一次主 actor 调度再读取最终状态。
            Task { @MainActor [weak self] in self?.observeNetworkObservationDemand() }
        }
        // 先恢复一次性订阅，再同步应用需求；中间不 await。
        model.connectionMonitor.setDemand(enabled: model.settings.canViewNetworkConnections,
                                          visible: model.isMainWindowVisible && model.settings.panelTab == .connections)
        model.networkGeography.setDemand(enabled: model.connectionMonitor.isReading)
    }

    /// 探测目标变化时清空历史重新探测；关闭公网 IP 查询时清除已显示的结果
    private func observeProbeSettings() {
        withObservationTracking {
            _ = model.settings.probeTarget
            _ = model.settings.publicIPLookup
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.model.network.restartProbing()
                self.model.network.clearPublicAddresses()
                if self.model.settings.publicIPLookup, self.model.isNetworkDetailVisible {
                    self.model.network.lookUpPublicAddresses()
                }
                self.observeProbeSettings()
            }
        }
    }

    /// AI 配额使用独立的分钟级轮询；开关或间隔变化时重建这一条调度，不影响系统指标采样。
    private func observeAIUsageSchedule() {
        withObservationTracking {
            _ = model.settings.aiUsageEnabled
            _ = model.settings.aiUsageSources
            _ = model.settings.aiUsageShowsLocalUsage
            _ = model.settings.aiUsageRefreshMinutes
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.model.aiUsage.start()
                // 模块关闭时移除菜单栏入口，切换主开关需要重算布局。
                self.menuBar.update()
                self.menuBar.refreshPopoverHeight()
                self.observeAIUsageSchedule()
            }
        }
    }

    /// 一次低频查询结束后只重绘菜单栏和弹窗；不重启轮询，避免形成刷新回路。
    private func observeAIUsageState() {
        withObservationTracking {
            _ = model.aiUsage.states
            _ = model.aiUsage.lastAttemptAt
            _ = model.settings.aiQuotaShowsRemaining
            _ = model.settings.aiUsageWesternUnits
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.menuBar.refreshImages()
                self.menuBar.refreshPopoverHeight()
                self.observeAIUsageState()
            }
        }
    }

    /// Widget 只读共享的展示摘要；所有凭据读取和网络查询仍留在主应用。
    private func observeWidgetState() {
        withObservationTracking {
            _ = model.settings.aiUsageEnabled
            _ = model.settings.aiUsageSources
            _ = model.settings.aiQuotaShowsRemaining
            _ = model.settings.aiUsageWesternUnits
            _ = model.settings.aiUsageShowsLocalUsage
            _ = model.settings.publicIPLookup
            _ = model.settings.language
            _ = model.settings.calendarFirstWeekday
            _ = model.settings.calendarFeatures
            _ = model.aiUsage.states
            _ = model.aiUsage.quotaStates
            _ = model.network.publicResults
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncWidgetSnapshot()
                self.observeWidgetState()
            }
        }
    }

    private func syncWidgetSnapshot() {
        let settings = model.settings
        let previous = widgetStore.load()
        let calendar = CalendarEngine.gregorian()
        let today = calendar.startOfDay(for: .now)
        let todayKey = CalendarEngine.today(at: today)?.id
        let dataVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let reusesCalendar = previous.calendarDataVersion == dataVersion
        let monthFeatures = settings.calendarFeatures.map(\.rawValue).sorted()
        // 多预备几天，Widget 午夜换日时无需唤醒主应用；主应用运行期间按小时补足窗口。
        let calendarDays: [WidgetSnapshot.CalendarSummary] = {
            if reusesCalendar, previous.showsSeasonal != nil,
               previous.showsAlmanac == true,
               previous.monthSummaries?.first?.featureKeys == monthFeatures, previous.calendarDays?.count == 8,
               previous.calendarDays?.first?.dateKey == todayKey {
                return previous.calendarDays ?? []
            }
            return (0..<8).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                      let day = CalendarEngine.today(at: date) else { return nil }
                return CalendarEngine.widgetSummary(for: day, features: settings.calendarFeatures)
            }
        }()
        let monthSummaries: [WidgetSnapshot.MonthSummary] = (0...1).compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: offset, to: today) else { return nil }
            let parts = calendar.dateComponents([.year, .month], from: date)
            guard let year = parts.year, let month = parts.month else { return nil }
            let key = WidgetSnapshot.monthKey(year: year, month: month)
            if reusesCalendar, let cached = previous.monthSummaries?.first(where: {
                $0.monthKey == key && $0.firstWeekday == settings.calendarFirstWeekday
                    && $0.featureKeys == monthFeatures && $0.days.count == 42
            }) {
                return cached
            }
            return CalendarEngine.widgetMonthSummary(year: year, month: month,
                                                     firstWeekday: settings.calendarFirstWeekday,
                                                     features: settings.calendarFeatures)
        }
        let quotas: [WidgetSnapshot.Quota] = settings.aiUsageEnabled
            ? AIProviderID.allCases.filter { settings.aiUsageSources.contains($0) }.flatMap { provider -> [WidgetSnapshot.Quota] in
                let state = model.aiUsage.quotaState(for: provider)
                guard let quota = state.snapshot else { return [] }
                return quota.windows.map { window in
                    WidgetSnapshot.Quota(provider: provider.rawValue, kind: window.kind.rawValue,
                                         remainingPercent: window.remainingPercent, resetsAt: window.resetsAt,
                                         fetchedAt: quota.fetchedAt, isStale: state.isStale)
                }
            } : []
        let dailyTokens: [WidgetSnapshot.DailyTokenUsage]? = settings.aiUsageEnabled && settings.aiUsageShowsLocalUsage
            ? AIProviderID.allCases.filter { settings.aiUsageSources.contains($0) }.compactMap { provider in
                guard let report = model.aiUsage.localReport(for: provider) else { return nil }
                let tokens = LocalUsageReport.total(report.selected(days: 1, now: today, calendar: calendar)).total
                return WidgetSnapshot.DailyTokenUsage(provider: provider.rawValue, day: today, tokens: tokens)
            } : nil
        let addresses: [WidgetSnapshot.Address] = settings.publicIPLookup
            ? IPFamily.allCases.compactMap { family in
                guard let result = model.network.publicResults[family],
                      let ip = family == .v4 ? result.ipv4 : result.ipv6 else { return nil }
                return WidgetSnapshot.Address(family: family.rawValue, ip: ip,
                                              countryCode: result.countryCode, city: result.city,
                                              organization: result.organization,
                                              purityScore: result.purity?.score, purityGrade: result.purity?.grade,
                                              region: result.region, cityEnglish: result.cityEnglish,
                                              regionEnglish: result.regionEnglish, asn: result.asn,
                                              isNative: result.isNative, ipType: result.ipType,
                                              riskFlags: result.risk?.flags)
            } : []
        let snapshot = WidgetSnapshot(aiEnabled: settings.aiUsageEnabled, quotas: quotas,
                                      dailyTokens: dailyTokens,
                                      localUsageEnabled: settings.aiUsageShowsLocalUsage,
                                      quotaShowsRemaining: settings.aiQuotaShowsRemaining,
                                      westernUnits: settings.aiUsageWesternUnits,
                                      publicIPEnabled: settings.publicIPLookup, addresses: addresses,
                                      language: settings.language.rawValue,
                                      calendarFirstWeekday: settings.calendarFirstWeekday,
                                      showsLunar: settings.calendarFeatures.contains(.lunar),
                                      calendarDays: calendarDays, monthSummaries: monthSummaries,
                                      showsSeasonal: settings.calendarFeatures.contains(.seasonalInfo),
                                      calendarDataVersion: dataVersion, showsAlmanac: true)
        guard snapshot != previous, widgetStore.save(snapshot) else { return }
        for kind in snapshot.changedWidgetKinds(from: previous) {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    private var appliedLanguage: AppLanguage?

    /// 切换语言后重建应用菜单、菜单栏图标文字与已打开的弹窗
    private func applyLanguageIfChanged() {
        let language = model.settings.language
        guard appliedLanguage != nil, appliedLanguage != language else {
            appliedLanguage = language
            return
        }
        appliedLanguage = language
        model.displays.refreshCatalog()
        NSApp.mainMenu = MainMenu.make(target: self, settingsAction: #selector(openSettingsFromMenu),
                                       updateAction: #selector(checkForUpdatesFromMenu))
        menuBar.dismissPopovers()
        menuBar.refreshImages(force: true)
        speedTestWindow.refreshLanguage()
        projectPurgeWindow.refreshLanguage()
        egressWindow.refreshLanguage()
        aiUsageSettingsWindow.refreshLanguage()
        updateWindow.refreshLanguage()
    }

    private func updateNetworkVisibility() {
        model.network.setVisibility(inMenuBar: model.drawnMenuBarItems.contains(.network),
                                    detailVisible: model.isNetworkDetailVisible)
    }

    private func applyAppearance() {
        switch model.settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 屏幕休眠、系统睡眠、切换用户、锁屏时暂停采样与探测；唤醒后重新下发风扇设置
    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let pauses: [Notification.Name] = [NSWorkspace.screensDidSleepNotification,
                                           NSWorkspace.willSleepNotification,
                                           NSWorkspace.sessionDidResignActiveNotification]
        let resumes: [Notification.Name] = [NSWorkspace.screensDidWakeNotification,
                                            NSWorkspace.didWakeNotification,
                                            NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pauses {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseForInactivity() }
            })
        }
        for name in resumes {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeFromInactivity() }
            })
        }
        // 锁屏后显示器可能仍亮着一段时间；这期间不应计入专注，也不应继续播放休息音效。
        let distributed = DistributedNotificationCenter.default()
        workspaceObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"),
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenLocked = true
                self?.pauseForInactivity()
            }
        })
        workspaceObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenLocked = false
                self?.resumeFromInactivity()
            }
        })
    }

    private func pauseForInactivity() {
        menuBar.dismissPopovers()
        model.network.setPaused(true)
        model.aiUsage.setPaused(true)
        model.displays.setPaused(true)
        model.audio.setPaused(true)
        model.connectionMonitor.setPaused(true)
        model.history.flush()
        restWindows.hideRest()
        rest.suspend()
        Task { await model.hub.setPaused(true) }
    }

    private func resumeFromInactivity() {
        // 系统唤醒时常仍停在锁屏界面，要等解锁后再恢复。
        guard !screenLocked else { return }
        model.network.setPaused(false)
        model.aiUsage.setPaused(false)
        model.displays.setPaused(false)
        model.audio.setPaused(false)
        model.connectionMonitor.setPaused(false)
        rest.sync()
        if rest.phase.isResting && rest.isRunning { restWindows.ensureRestVisible() }
        Task {
            await model.hub.setPaused(false)
            await model.fans.reapply()
        }
    }

    private func observeRestSettings() {
        withObservationTracking {
            _ = model.settings.restEnabled
            _ = model.settings.restWorkMinutes
            _ = model.settings.restBreakMinutes
            _ = model.settings.restLongBreakMinutes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rest.restart()
                self.restMenuBar.sync()
                if !self.model.settings.restEnabled { self.restWindows.hideHUD() }
                self.observeRestSettings()
            }
        }
    }

    /// 关闭清理模块时停止尚未结束的扫描或清理，并关闭其独立窗口。
    private func observeCleanerSetting() {
        withObservationTracking {
            _ = model.settings.cleanerEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.model.settings.cleanerEnabled {
                    self.model.cleaner.cancelClean()
                    self.model.cleaner.cancelOperation()
                    self.model.projectPurge.isConfirming = false
                    self.model.projectPurge.cancelScan()
                    self.model.projectPurge.cancelClean()
                    self.projectPurgeWindow.close()
                }
                self.observeCleanerSetting()
            }
        }
    }

    private func observeRestMode() {
        withObservationTracking {
            _ = model.settings.restMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rest.modeDidChange()
                self.observeRestMode()
            }
        }
    }

    private func observeRestSound() {
        withObservationTracking {
            _ = model.settings.restSound
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.rest.syncSound()
                self?.observeRestSound()
            }
        }
    }
}

public enum XStatsApplication {
    @MainActor
    public static func main() {
        // 只读诊断子进程不启动 UI、采样或更新服务，也不写入应用偏好。
        if CommandLine.arguments.contains(AppleIntelligenceDiagnostics.argument) {
            AppleIntelligenceDiagnostics.writeReport()
            return
        }
        // 滚动条一律用浮层样式：接了鼠标时系统默认是常驻滚动条，SwiftUI 的 ScrollView 会给它预留一条宽度，
        // 弹窗里的内容就会整体偏左。这是本应用自己的偏好域，只影响 XStats
        if CommandLine.arguments.contains("--snapshot") {
            UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "WhenScrolling"])
        } else {
            UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        }
        let app = NSApplication.shared
        // 界面语言在创建任何界面之前确定，切换后重启生效
        let stored = UserDefaults.standard.string(forKey: AppSettings.languageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        L10n.configure(stored)
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let path = CommandLine.arguments.dropFirst(index + 1).first ?? "snapshots"
            // --language 接受语言代码或设置枚举值，缺失翻译记录到 untranslated.txt。
            if let languageIndex = CommandLine.arguments.firstIndex(of: "--language"),
               let identifier = CommandLine.arguments.dropFirst(languageIndex + 1).first {
                let language = AppLanguage(rawValue: identifier) ?? AppLanguage.resolve(preferredLanguages: [identifier])
                L10n.configure(language)
                let log = URL(fileURLWithPath: path).appendingPathComponent("untranslated.txt")
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: log)
                L10n.missLog = log
            }
            app.setActivationPolicy(.prohibited)
            Task {
                await SnapshotRenderer.run(outputDirectory: URL(fileURLWithPath: path))
                exit(SnapshotRenderer.didFail ? 1 : 0)
            }
            app.run()
            return
        }
        stored.applyToProcessLocale()

        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) {
            app.run()
        }
    }
}
