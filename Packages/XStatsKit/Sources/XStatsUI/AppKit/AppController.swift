import AppKit
import Localization
import Metrics
import SwiftUI

@MainActor
public final class AppController: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var menuBar: MenuBarController!
    private var mainWindow: MainWindowController!
    private var updateWindow: UpdateWindowController!
    private var speedTestWindow: SpeedTestWindowController!
    private var egressWindow: EgressWindowController!
    private var updateTimer: Timer?
    private let hotKeys = HotKeyCenter()
    private var workspaceObservers: [NSObjectProtocol] = []

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
        mainWindow = MainWindowController(model: model)
        mainWindow.onVisibilityChange = { [weak self] _ in self?.updateActivationPolicy() }
        updateWindow = UpdateWindowController(model: model)
        speedTestWindow = SpeedTestWindowController(model: model)
        speedTestWindow.onVisibilityChange = { [weak self] _ in self?.updateActivationPolicy() }
        egressWindow = EgressWindowController(model: model)
        egressWindow.onVisibilityChange = { [weak self] _ in self?.updateActivationPolicy() }
        menuBar.update()

        // 设置已并入主窗口：所有“设置…”入口都打开主窗口的通用设置
        model.openSettings = { [weak self] in
            self?.menuBar.dismissPopovers()
            self?.mainWindow.show(tab: .settingsGeneral)
        }
        model.openMainWindow = { [weak self] tab in
            self?.menuBar.dismissPopovers()
            self?.mainWindow.show(tab: tab)
        }
        model.openEgressWindow = { [weak self] in
            self?.menuBar.dismissPopovers()
            self?.egressWindow.show()
        }
        model.openSpeedTestWindow = { [weak self] in
            self?.menuBar.dismissPopovers()
            self?.speedTestWindow.show()
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
        observeModel()
        observeProbeSettings()
        applyAppearance()
        updateNetworkVisibility()
        appliedLanguage = model.settings.language
        startUpdateChecks()
        model.alerts.openTab = { [weak self] tab in
            self?.menuBar.dismissPopovers()
            self?.mainWindow.show(tab: tab)
        }
        model.alerts.start()
        hotKeys.onAction = { [weak self] action in self?.perform(action) }
        applyHotKeys()

        // 开发调试：--show-panel [overview|cpu|memory|network|gpu|disk|temperature|fan|battery] 启动后展开并固定弹窗
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
        if let index = arguments.firstIndex(of: "--explain-process"), let name = arguments.dropFirst(index + 1).first {
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
        Task { [weak self] in
            await appModel.hub.update(appModel.demand)
            await appModel.hub.start { [weak self] snapshot in
                appModel.handle(snapshot)
                self?.menuBar.refreshImages()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
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
            mainWindow.show(tab: .processes)
        case .toggleKeepAwake:
            Task { await model.keepAwake.setActive(!model.keepAwake.isActive) }
        case .purgeMemory:
            Task { await model.maintenance.run(.purgeMemory) }
        }
    }

    /// 启动 10 秒后检查一次，之后每小时看一眼是否已满一天（上次失败则直接重试）
    private func startUpdateChecks() {
        model.updates.onPrompt = { [weak self] in
            self?.menuBar.dismissPopovers()
            self?.updateWindow.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.model.updates.checkIfNeeded()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.updates.checkIfNeeded() }
        }
        updateTimer?.tolerance = 5 * 60
    }

    /// 默认只在菜单栏运行、不占程序坞；打开了“在程序坞显示图标”时，有窗口开着才出现在程序坞与 ⌘Tab 里
    private func updateActivationPolicy() {
        let hasWindow = mainWindow.isVisible || egressWindow.isVisible || speedTestWindow.isVisible
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
            _ = model.settings.menuBarItems
            _ = model.settings.menuBarLayout
            _ = model.settings.menuBarStyle
            _ = model.settings.networkStyle
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
            _ = model.settings.language
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyLanguageIfChanged()
                self.model.alerts.applySettings()
                await self.model.hub.update(self.model.demand)
                self.model.bluetooth.setDemand(self.model.bluetoothDemand)
                self.applyAppearance()
                self.updateActivationPolicy()
                self.menuBar.update()
                self.menuBar.refreshPopoverHeight()
                self.updateNetworkVisibility()
                self.observeModel()
            }
        }
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

    private var appliedLanguage: AppLanguage?

    /// 切换语言后重建应用菜单、菜单栏图标文字与已打开的弹窗
    private func applyLanguageIfChanged() {
        let language = model.settings.language
        guard appliedLanguage != nil, appliedLanguage != language else {
            appliedLanguage = language
            return
        }
        appliedLanguage = language
        NSApp.mainMenu = MainMenu.make(target: self, settingsAction: #selector(openSettingsFromMenu),
                                       updateAction: #selector(checkForUpdatesFromMenu))
        menuBar.dismissPopovers()
        menuBar.refreshImages()
    }

    private func updateNetworkVisibility() {
        model.network.setVisibility(inMenuBar: model.settings.menuBarItems.contains(.network),
                                    detailVisible: model.isNetworkDetailVisible)
    }

    private func applyAppearance() {
        switch model.settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 屏幕休眠、系统睡眠、切换用户时暂停采样与探测；唤醒后重新下发风扇设置
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
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuBar.dismissPopovers()
                    self.model.network.setPaused(true)
                    self.model.history.flush()
                    Task { await self.model.hub.setPaused(true) }
                }
            })
        }
        for name in resumes {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.network.setPaused(false)
                    Task {
                        await self.model.hub.setPaused(false)
                        await self.model.fans.reapply()
                    }
                }
            })
        }
    }
}

public enum XStatsApplication {
    @MainActor
    public static func main() {
        // 滚动条一律用浮层样式：接了鼠标时系统默认是常驻滚动条，SwiftUI 的 ScrollView 会给它预留一条宽度，
        // 弹窗里的内容就会整体偏左。这是本应用自己的偏好域，只影响 XStats
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        let app = NSApplication.shared
        // 界面语言在创建任何界面之前确定，切换后重启生效
        let stored = UserDefaults.standard.string(forKey: AppSettings.languageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        L10n.configure(stored)
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let path = CommandLine.arguments.dropFirst(index + 1).first ?? "snapshots"
            // --language en：渲染英文截图，并把没有翻译的中文记到 untranslated.txt
            if let languageIndex = CommandLine.arguments.firstIndex(of: "--language"),
               CommandLine.arguments.dropFirst(languageIndex + 1).first == "en" {
                L10n.configure(.english)
                let log = URL(fileURLWithPath: path).appendingPathComponent("untranslated.txt")
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: log)
                L10n.missLog = log
            }
            app.setActivationPolicy(.prohibited)
            Task {
                await SnapshotRenderer.run(outputDirectory: URL(fileURLWithPath: path))
                exit(0)
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
