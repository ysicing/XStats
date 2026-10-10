import AppKit
import Foundation
import SwiftUI
@testable import Metrics
import Testing
import Updates
@testable import XStatsUI

private func isolatedDefaults() -> UserDefaults {
    let name = "XStatsUITests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
@Suite struct UpdatePromptLayoutTests {
    @Test func releaseSummaryDoesNotLeaveAnEmptyHeaderRow() {
        let model = AppModel(settings: AppSettings(defaults: isolatedDefaults()), historyURL: nil, aiUsageProviders: [])
        model.updates.showPreview(UpdateRelease(
            version: "0.8.1", build: "113", date: "2026-09-23", minimumSystem: "14.0",
            url: URL(string: "https://example.test/XStats.zip")!, sha256: String(repeating: "a", count: 64),
            size: 6_889_522, dmg: nil,
            notes: ["在“设置 → 关于”提供服务条款和隐私政策，说明本机数据、更新统计、第三方联网功能及用户自行配…",
                    "卸载应用时增加明确的二次确认，展示将移入废纸篓的项目与可恢复提示",
                    "优化法律文档的关闭入口及标题、段落、列表排版，避免正文挤成一段"],
            changelog: nil))
        let hosting = NSHostingView(rootView: UpdatePromptView {}.environment(model))

        #expect(hosting.fittingSize.height < 320)
    }
}

@MainActor
@Suite struct ToolBrandLogoTests {
    @Test(arguments: ["site-openai", "site-claude"])
    func brandLogosCanBeCachedAsBothColorAndMenuBarTemplates(_ name: String) throws {
        let color = try #require(LogoCache.shared.image(named: name, template: false))
        let template = try #require(LogoCache.shared.image(named: name, template: true))
        #expect(!color.isTemplate)
        #expect(template.isTemplate)
        #expect(color !== template)
    }

    @Test(arguments: ["github", "tool-npm", "tool-yarn", "tool-pnpm", "tool-bun",
                      "tool-go", "tool-rust", "tool-uv"])
    func packagedSVGCanBeRenderedAsTemplate(_ name: String) throws {
        let image = try #require(LogoCache.shared.image(named: name, template: true))
        #expect(image.isTemplate)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test(arguments: ChinaCarrier.allCases)
    func carrierLogoIsPackagedInColor(_ carrier: ChinaCarrier) throws {
        let name = "carrier-" + String(describing: carrier)
        let image = try #require(LogoCache.shared.image(named: name, template: false))
        #expect(!image.isTemplate)
        #expect(image.size.width > 0 && image.size.height > 0)
    }
}

@MainActor
@Suite struct BluetoothDeviceCacheTests {
    private func device(_ name: String, percent: Int) -> BluetoothDevice {
        BluetoothDevice(name: name, address: "", kind: .other, batteries: [("电量", percent)])
    }

    @Test func retainsDisconnectedDevicesForThirtyMinutes() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = BluetoothDeviceCache(retention: 30 * 60)
        _ = cache.merge(current: [device("耳机", percent: 76), device("触控板", percent: 24)], now: start)

        let recent = cache.merge(current: [device("触控板", percent: 23)], now: start.addingTimeInterval(60))

        let headphones = try #require(recent.first { $0.name == "耳机" })
        #expect(!headphones.isConnected)
        #expect(headphones.lastSeen == start)
        #expect(BluetoothController.lowest(in: recent)?.device.name == "触控板")

        let expired = cache.merge(current: [device("触控板", percent: 22)], now: start.addingTimeInterval(30 * 60 + 1))
        #expect(!expired.contains { $0.name == "耳机" })
    }

    @Test func disconnectedDeviceDoesNotKeepChargingStatus() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = BluetoothDeviceCache()
        var trackpad = device("Magic Trackpad", percent: 69)
        trackpad.isCharging = true
        _ = cache.merge(current: [trackpad], now: start)

        let disconnected = try #require(cache.merge(current: [], now: start.addingTimeInterval(60)).first)
        #expect(!disconnected.isConnected)
        #expect(disconnected.isCharging == nil)
    }

    @Test func keepsSameNameDevicesSeparateByAddress() {
        let start = Date(timeIntervalSince1970: 2_000)
        var cache = BluetoothDeviceCache(retention: 30 * 60)
        var first = device("Gamepad", percent: 80)
        first.address = "AA:AA"
        var second = device("Gamepad", percent: 60)
        second.address = "BB:BB"

        _ = cache.merge(current: [first, second], now: start)
        let recent = cache.merge(current: [first], now: start.addingTimeInterval(60))

        #expect(recent.count == 2)
        #expect(recent.first { $0.address == "AA:AA" }?.isConnected == true)
        #expect(recent.first { $0.address == "BB:BB" }?.isConnected == false)
    }

    @Test func upgradesNameIdentityWhenAddressAppears() {
        let start = Date(timeIntervalSince1970: 3_000)
        var cache = BluetoothDeviceCache(retention: 30 * 60)
        let nameOnly = device("Headphones", percent: 76)
        var withAddress = device("Headphones", percent: 75)
        withAddress.address = "CC:CC"

        _ = cache.merge(current: [nameOnly], now: start)
        let current = cache.merge(current: [withAddress], now: start.addingTimeInterval(60))

        #expect(current.count == 1)
        #expect(current.first?.address == "CC:CC")
        #expect(current.first?.isConnected == true)
        #expect(current.first?.batteries.first?.percent == 75)
    }

    @Test func expiredIdentityDoesNotMigrateToNewNameOnlyDevice() {
        let start = Date(timeIntervalSince1970: 4_000)
        var cache = BluetoothDeviceCache(retention: 30 * 60)
        var old = device("Headphones", percent: 76)
        old.address = "DD:DD"

        _ = cache.merge(current: [old], now: start)
        let current = cache.merge(current: [device("Headphones", percent: 90)],
                                  now: start.addingTimeInterval(30 * 60 + 1))

        #expect(current.count == 1)
        #expect(current.first?.address.isEmpty == true)
        #expect(current.first?.batteries.first?.percent == 90)
    }

    @Test func showsPairedAccessoryWithoutBatteryAsDisconnected() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        var cache = BluetoothDeviceCache(retention: 30 * 60)
        var paired = device("Headphones", percent: 0)
        paired.address = "EE:EE"
        paired.batteries = []
        paired.isConnected = false

        let devices = cache.merge(current: [paired], now: now)

        let headphones = try #require(devices.first)
        #expect(!headphones.isConnected)
        #expect(headphones.batteries.isEmpty)
        #expect(headphones.lastSeen == nil)
        #expect(BluetoothController.lowest(in: devices) == nil)
    }

    @Test func disconnectedMetadataUsesRecentBattery() throws {
        let start = Date(timeIntervalSince1970: 6_000)
        var cache = BluetoothDeviceCache(retention: 30 * 60)
        var connected = device("Headphones", percent: 76)
        connected.address = "FF:FF"
        _ = cache.merge(current: [connected], now: start)

        var paired = connected
        paired.batteries = []
        paired.isConnected = false
        let devices = cache.merge(current: [paired], now: start.addingTimeInterval(60))

        let headphones = try #require(devices.first)
        #expect(!headphones.isConnected)
        #expect(headphones.batteries.first?.percent == 76)
        #expect(headphones.lastSeen == start)
    }
}

@MainActor
@Suite struct BluetoothAlertCandidateTests {
    @Test func keepsConnectedDevicesForAlertStateUpdates() {
        let connectedLow = BluetoothDevice(name: "Mouse", address: "AA", kind: .mouse, batteries: [("电量", 10)])
        var disconnectedLow = BluetoothDevice(name: "Headphones", address: "BB", kind: .headphones, batteries: [("电量", 5)])
        disconnectedLow.isConnected = false
        let connectedHealthy = BluetoothDevice(name: "Keyboard", address: "CC", kind: .keyboard, batteries: [("电量", 80)])

        let candidates = AlertController.connectedBluetoothDevices([connectedLow, disconnectedLow, connectedHealthy])

        #expect(candidates.map(\.name) == ["Mouse", "Keyboard"])
    }
}

@Suite struct BluetoothDeviceRowLayoutTests {
    @Test func expandsOnlyMultipartBatteries() {
        #expect(BluetoothDeviceRowLayout(batteryCount: 0) == .compact)
        #expect(BluetoothDeviceRowLayout(batteryCount: 1) == .compact)
        #expect(BluetoothDeviceRowLayout(batteryCount: 2) == .parts)
        #expect(BluetoothDeviceRowLayout(batteryCount: 3) == .parts)
    }
}

@MainActor
@Suite struct SettingsTests {
    @Test(arguments: [false, true], [CGFloat(1), CGFloat(2)])
    func settingsPreviewRasterizesOnceAndKeepsAppearanceColors(dark: Bool, scale: CGFloat) throws {
        var draws = 0
        let source = NSImage(size: NSSize(width: 40, height: 18), flipped: false) { rect in
            draws += 1
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        source.isTemplate = true
        let preview = MenuBarRenderer.preview(source, dark: dark, backingScale: scale)
        let drawsAfterRender = draws
        #expect(drawsAfterRender >= 1)
        // 反复读取预览（布局、重绘）不能再触发源图的绘制回调。
        for _ in 0..<5 { _ = preview.tiffRepresentation }
        #expect(draws == drawsAfterRender)
        #expect(preview.size == source.size)
        #expect(preview.representations.contains { $0 is NSBitmapImageRep })
        // 模板图按外观着色：浅色外观为黑，深色外观为白。
        let rep = try #require(preview.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        #expect(rep.pixelsWide == Int(source.size.width * scale))
        #expect(rep.pixelsHigh == Int(source.size.height * scale))
        let center = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(center.alphaComponent > 0.99)
        #expect((center.redComponent > 0.5) == dark)
        // 源图铺满整个画布，四角也应被着色；缩放错位时角落会留空或越界。
        for (x, y) in [(0, 0), (rep.pixelsWide - 1, 0), (0, rep.pixelsHigh - 1), (rep.pixelsWide - 1, rep.pixelsHigh - 1)] {
            let corner = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            #expect(corner.alphaComponent > 0.99)
            #expect((corner.redComponent > 0.5) == dark)
        }
    }

    @Test func stackedCenteredStyleRendersDifferentPlacementAtSameWidth() {
        #expect(MenuBarStyle.options(for: .fan).contains(.stackedCenter))
        var reading = MenuBarReading.sample
        reading.fanRPM = 0
        let aligned = MenuBarRenderer.image(reading: reading, items: [.fan],
                                            style: { _ in .stacked }, networkStyle: .dots,
                                            colorizeHighLoad: false, fahrenheit: false)
        let centered = MenuBarRenderer.image(reading: reading, items: [.fan],
                                             style: { _ in .stackedCenter }, networkStyle: .dots,
                                             colorizeHighLoad: false, fahrenheit: false)
        #expect(aligned.size == centered.size)
        #expect(aligned.tiffRepresentation != centered.tiffRepresentation)
    }

    @Test func centeredStylePersistsAndRestoresFromBackup() {
        let source = AppSettings(defaults: isolatedDefaults())
        source.menuBarStyle = .stackedCenter
        source.styleOverrides = [.fan: .stackedCenter]
        let target = AppSettings(defaults: isolatedDefaults())
        target.apply(source.exportDocument())
        #expect(target.menuBarStyle == .stackedCenter)
        #expect(target.styleOverrides[.fan] == .stackedCenter)
    }

    @Test func defaultsAndInvalidValues() {
        let defaults = isolatedDefaults()
        defaults.set(7, forKey: "refreshSeconds")
        defaults.set("bogus", forKey: "panelTab")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.refreshSeconds == 2)
        #expect(settings.panelTab == .overview)
        #expect(settings.menuBarItems == [.cpu, .memory, .network])
        #expect(settings.probeEnabled && settings.probeInBackground && settings.autoCheckUpdates)
        #expect(settings.speedTestRoute == .direct)
        // 从未调整过弹窗区块时，默认隐藏的区块生效；走势默认 1 分钟
        #expect(settings.hiddenPopoverSections == PopoverSection.hiddenByDefault)
        #expect(!settings.isVisible(.cpuCores) && settings.isVisible(.cpuHeatmap))
        #expect(settings.cpuChartSeconds == 60)
    }

    @Test func persistsChanges() {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.menuBarItems = [.gpu, .fan]
        settings.probeInBackground = false
        settings.speedTestRoute = .proxy
        settings.hiddenPopoverSections = [.cpuHeatmap]
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.menuBarItems == [.gpu, .fan])
        #expect(!reloaded.probeInBackground)
        #expect(reloaded.speedTestRoute == .proxy)
        #expect(reloaded.hiddenPopoverSections == [.cpuHeatmap])
        #expect(reloaded.orderedMenuBarItems == [.gpu, .fan])
    }

    @Test func speedTestRouteRoundTripsBackupAndIgnoresUnknownValues() {
        let source = AppSettings(defaults: isolatedDefaults())
        source.speedTestRoute = .proxy
        let target = AppSettings(defaults: isolatedDefaults())
        target.apply(source.exportDocument())
        #expect(target.speedTestRoute == .proxy)

        var unknown = SettingsDocument()
        unknown.speedTestRoute = "unsupported"
        target.apply(unknown)
        #expect(target.speedTestRoute == .proxy)
    }
}

@MainActor
@Suite struct CleanerFeatureTests {
    @Test func defaultsOffAndHidesSavedPageWhenDisabled() {
        let defaults = isolatedDefaults()
        defaults.set("cleaner", forKey: "panelTab")
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.cleanerEnabled)
        #expect(settings.panelTab == .settingsFeatures)

        let cleaner = CleanerController(settings: settings)
        cleaner.scan()
        #expect(cleaner.phase == .idle)

        settings.cleanerEnabled = true
        settings.panelTab = .cleaner
        #expect(AppSettings(defaults: defaults).panelTab == .cleaner)

        settings.cleanerEnabled = false
        #expect(settings.panelTab == .settingsFeatures)
        #expect(!AppSettings(defaults: defaults).cleanerEnabled)
        defaults.set("cleaner", forKey: "panelTab")
        #expect(AppSettings(defaults: defaults).panelTab == .settingsFeatures)
    }

    @Test func backupRestoresModulePreferenceAndOldBackupKeepsCurrentValue() throws {
        let source = AppSettings(defaults: isolatedDefaults())
        source.cleanerEnabled = true
        let data = try JSONEncoder().encode(source.exportDocument())
        let document = try JSONDecoder().decode(SettingsDocument.self, from: data)
        #expect(document.cleanerEnabled == true)

        let target = AppSettings(defaults: isolatedDefaults())
        target.apply(document)
        #expect(target.cleanerEnabled)
        target.apply(SettingsDocument())
        #expect(target.cleanerEnabled)
    }
}

@MainActor
@Suite struct CleanerSelectionTests {
    private let toolRuleIDs: Set<String> = [
        "developer.npm", "developer.yarn", "developer.pnpm", "developer.bun",
        "developer.go", "developer.rust", "developer.uv",
    ]

    @Test func toolCachesStartUnselected() {
        let controller = CleanerController(settings: AppSettings(defaults: isolatedDefaults()))

        #expect(controller.selection.isDisjoint(with: toolRuleIDs))
        #expect(controller.selection.contains("system.caches"))
    }

    @Test func userSelectionSurvivesControllerAndSettingsRecreation() {
        let defaults = isolatedDefaults()
        let controller = CleanerController(settings: AppSettings(defaults: defaults))
        controller.selection.insert("developer.pnpm")

        let reloaded = CleanerController(settings: AppSettings(defaults: defaults))

        #expect(reloaded.selection.contains("developer.pnpm"))
    }

    @Test func explicitlyClearingSelectionDoesNotRestoreDefaults() {
        let defaults = isolatedDefaults()
        let controller = CleanerController(settings: AppSettings(defaults: defaults))
        controller.selection.removeAll()

        let reloaded = CleanerController(settings: AppSettings(defaults: defaults))

        #expect(reloaded.selection.isEmpty)
    }
}

@MainActor
@Suite struct ProjectPurgePathTests {
    @Test func defaultPathsCanBeRemovedAndRestored() async throws {
        let defaults = isolatedDefaults()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-project-paths-\(UUID())")
        let projects = home.appendingPathComponent("Projects")
        let dev = home.appendingPathComponent("dev")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let controller = ProjectPurgeController(settings: AppSettings(defaults: defaults), home: home.path)
        await controller.loadPaths()
        #expect(Set(controller.roots.map(\.lastPathComponent)) == ["Projects", "dev"])
        controller.removeRoot(projects)
        #expect(controller.roots.map(\.lastPathComponent) == ["dev"])

        let reloaded = ProjectPurgeController(settings: AppSettings(defaults: defaults), home: home.path)
        await reloaded.loadPaths()
        #expect(reloaded.roots.map(\.lastPathComponent) == ["dev"])
        await reloaded.restoreDefaults()
        #expect(Set(reloaded.roots.map(\.lastPathComponent)) == ["Projects", "dev"])
        #expect(AppSettings(defaults: defaults).projectPurgeConfiguredPaths == nil)
    }

    @Test func addedRootsPersistAndDuplicatesAreRejected() async throws {
        let defaults = isolatedDefaults()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-project-paths-\(UUID())")
        let projects = home.appendingPathComponent("Projects")
        let extra = home.appendingPathComponent("Work")
        let extraAlias = home.appendingPathComponent("WorkAlias")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: extraAlias, withDestinationURL: extra)
        defer { try? FileManager.default.removeItem(at: home) }

        let controller = ProjectPurgeController(settings: AppSettings(defaults: defaults), home: home.path)
        await controller.loadPaths()
        #expect(controller.addRoot(extra))
        #expect(!controller.addRoot(extra))
        #expect(!controller.addRoot(extraAlias))
        #expect(!controller.addRoot(projects))

        let reloaded = ProjectPurgeController(settings: AppSettings(defaults: defaults), home: home.path)
        await reloaded.loadPaths()
        #expect(Set(reloaded.roots.map(\.lastPathComponent)) == ["Projects", "Work"])
        reloaded.removeRoot(extra)
        #expect(reloaded.roots.map(\.lastPathComponent) == ["Projects"])
    }

    @Test func unsafeRootsAreRejected() async {
        let controller = ProjectPurgeController(settings: AppSettings(defaults: isolatedDefaults()))
        await controller.loadPaths()
        #expect(!controller.addRoot(URL(fileURLWithPath: "/")))
        #expect(!controller.addRoot(FileManager.default.homeDirectoryForCurrentUser))
        #expect(!controller.addRoot(URL(fileURLWithPath: "/System")))
        #expect(!controller.addRoot(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")))
    }
}

@Suite struct PanelTabTests {
    @MainActor @Test func featuresPageRestoresWithoutChangingModulePreferences() {
        let defaults = isolatedDefaults()
        defaults.set("settingsFeatures", forKey: "panelTab")
        defaults.set(true, forKey: "restEnabled")
        defaults.set(true, forKey: "calendarEnabled")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.panelTab == .settingsFeatures)
        #expect(settings.restEnabled && settings.calendarEnabled)
        #expect(!settings.audioEnabled && !settings.aiUsageEnabled)
        #expect(!settings.processesEnabled && !settings.cleanerEnabled)
        #expect(PanelTab.settings.prefix(2) == [.settingsGeneral, .settingsFeatures])
    }

    @MainActor @Test func removedAssistantPageRestoresToGeneralSettings() {
        let defaults = isolatedDefaults()
        defaults.set("settingsAI", forKey: "panelTab")
        #expect(AppSettings(defaults: defaults).panelTab == .settingsGeneral)
    }

    @MainActor @Test func hiddenSyncPageRestoresToGeneralSettings() {
        let defaults = isolatedDefaults()
        defaults.set("settingsAccount", forKey: "panelTab")
        #expect(AppSettings(defaults: defaults).panelTab == .settingsGeneral)
    }

    @Test func sidebarGroupsCoverEveryTabOnce() {
        let grouped = PanelTab.monitors + PanelTab.tools + PanelTab.settings
        let visible = PanelTab.allCases.filter { $0 != .settingsAccount }
        #expect(grouped.count == visible.count)
        #expect(Set(grouped) == Set(visible))
        #expect(PanelTab.settings.allSatisfy { $0.isSettings })
        #expect(PanelTab.settingsAbout.headerTitle == "设置 · 关于")
    }

    @Test func menuBarItemsMapToPages() {
        for item in MenuBarItem.allCases {
            let tab = PanelTab(item: item)
            #expect(tab.menuBarItem == item || (item == .fan && tab == .thermal))
        }
    }
}

@MainActor
@Suite struct DemandTests {
    private func model() -> AppModel {
        AppModel(settings: AppSettings(defaults: isolatedDefaults()), historyURL: nil)
    }

    @Test func hidingApplicationDropsWindowDemandAndUnhideDoesNotInventAWindow() {
        let model = model()
        let controller = MainWindowController(model: model)
        model.isMainWindowVisible = true
        model.settings.panelTab = .processes
        // ⌘H 不关闭也不最小化窗口；只有应用隐藏通知能让页面需求停止。
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
        #expect(!model.isMainWindowVisible)
        // 窗口从未显示时，取消隐藏不能把可见性误报为 true。
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: nil)
        #expect(!model.isMainWindowVisible)
        withExtendedLifetime(controller) {}
    }

    @Test func menuBarOnlySamplesAtUserInterval() {
        let model = model()
        model.settings.refreshSeconds = 5
        #expect(model.demand.interval == .seconds(5))
        #expect(!model.demand.systemProcesses)
        #expect(!model.demand.disk)
    }

    @Test func processesPageRefreshesEveryTwoSeconds() {
        let model = model()
        model.settings.processesEnabled = true
        model.isMainWindowVisible = true
        model.settings.panelTab = .processes
        #expect(model.demand.interval == .seconds(2))
        #expect(model.demand.processes && model.demand.systemProcesses)

        model.openPopover = .cpu
        #expect(model.demand.interval == .seconds(1))

        model.openPopover = nil
        model.settings.panelTab = .overview
        #expect(model.demand.interval == .seconds(1))
        #expect(!model.demand.systemProcesses)
    }

    @Test func staticPagesUseUserIntervalWhileLivePagesStayResponsive() {
        let model = model()
        model.settings.refreshSeconds = 5
        model.isMainWindowVisible = true

        for tab: PanelTab in [.history, .aiUsage, .keepAwake, .cleaner, .uninstaller,
                              .startupItems, .settingsGeneral, .settingsFeatures, .settingsMenuBar,
                              .settingsNotifications, .settingsAccount, .settingsHelper, .settingsAbout] {
            model.settings.panelTab = tab
            #expect(model.demand.interval == .seconds(5), "\(tab) should use the configured interval")
        }

        for tab: PanelTab in [.overview, .system, .cpu, .gpu, .memory, .disk,
                              .network, .thermal, .battery] {
            model.settings.panelTab = tab
            #expect(model.demand.interval == .seconds(1), "\(tab) should refresh live metrics")
        }

        model.settings.panelTab = .settingsAbout
        model.openPopover = .cpu
        #expect(model.demand.interval == .seconds(1))
    }

    @Test func popoversWithoutLiveMetricsKeepSamplingInterval() {
        let model = model()
        model.settings.refreshSeconds = 5
        for item: MenuBarItem in [.aiUsage, .display] {
            model.openPopover = item
            #expect(model.demand.interval == .seconds(5), "\(item) popover should not boost sampling")
        }

        model.settings.processesEnabled = true
        model.isMainWindowVisible = true
        model.settings.panelTab = .processes
        #expect(model.demand.interval == .seconds(2))
    }

    @Test func networkDetailVisibility() {
        let model = model()
        #expect(!model.isNetworkDetailVisible)
        model.openPopover = .network
        #expect(model.isNetworkDetailVisible)
        model.openPopover = nil
        model.isMainWindowVisible = true
        model.settings.panelTab = .network
        #expect(model.isNetworkDetailVisible)
    }
}

@MainActor
@Suite struct UpdateControllerTests {
    @Test func updateSchedulesRespectLaunchAndElapsedIntervals() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oneDayAgo = now.addingTimeInterval(-24 * 60 * 60)
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: now)!

        let launch = now.addingTimeInterval(-60 * 60)
        #expect(UpdateCheckSchedule.never.shouldCheck(lastChecked: nil, now: now, launchedAt: launch) == false)
        // “启动时”：本次运行尚未成功检查（上次在启动前或从未检查）就一直待办，失败后可由定时器重试
        #expect(UpdateCheckSchedule.atLaunch.shouldCheck(lastChecked: nil, now: now, launchedAt: launch))
        #expect(UpdateCheckSchedule.atLaunch.shouldCheck(lastChecked: oneDayAgo, now: now, launchedAt: launch))
        #expect(!UpdateCheckSchedule.atLaunch.shouldCheck(lastChecked: launch.addingTimeInterval(10), now: now, launchedAt: launch))
        #expect(UpdateCheckSchedule.daily.shouldCheck(lastChecked: oneDayAgo, now: now, launchedAt: launch))
        #expect(UpdateCheckSchedule.quietRuntime.shouldCheck(lastChecked: oneDayAgo, now: now, launchedAt: launch))
        #expect(!UpdateCheckSchedule.quietRuntime.promptsForUpdates)
        #expect(!UpdateCheckSchedule.weekly.shouldCheck(lastChecked: sixDaysAgo, now: now, launchedAt: launch))
        #expect(UpdateCheckSchedule.weekly.shouldCheck(lastChecked: sevenDaysAgo, now: now, launchedAt: launch))
        #expect(UpdateCheckSchedule.monthly.shouldCheck(lastChecked: monthAgo, now: now, launchedAt: launch))
    }

    @Test func legacyAutomaticUpdatePreferenceMigratesToSchedule() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: "autoCheckUpdates")
        #expect(AppSettings(defaults: defaults).updateCheckSchedule == .never)
        defaults.set(true, forKey: "autoCheckUpdates")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.updateCheckSchedule == .daily)
        settings.updateCheckSchedule = .monthly
        #expect(AppSettings(defaults: defaults).updateCheckSchedule == .monthly)
    }

    @Test func updateScheduleBackupRestoresNewAndLegacyFormats() {
        let source = AppSettings(defaults: isolatedDefaults())
        source.updateCheckSchedule = .weekly
        let target = AppSettings(defaults: isolatedDefaults())
        target.apply(source.exportDocument())
        #expect(target.updateCheckSchedule == .weekly)

        var legacy = SettingsDocument()
        legacy.autoCheckUpdates = false
        target.apply(legacy)
        #expect(target.updateCheckSchedule == .never)
    }

    @Test func launchScheduleSkipsOnlyAfterACheckSucceededThisRun() {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.updateCheckSchedule = .atLaunch
        let launch = Date()
        // 本次启动后已成功检查过：定时器再触发也不重复请求
        defaults.set(launch.addingTimeInterval(1), forKey: "updateLastChecked")
        let checked = UpdateController(settings: settings, defaults: defaults, launchedAt: launch)
        checked.checkIfNeeded()
        #expect(checked.phase == .idle)
        // 待办分支会真实联网上报，只在 shouldCheck 的纯函数测试里覆盖
    }

    @Test func automaticCheckRespectsSettingAndInterval() {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.autoCheckUpdates = false
        let controller = UpdateController(settings: settings, defaults: defaults)
        controller.checkIfNeeded()
        #expect(controller.phase == .idle)

        settings.autoCheckUpdates = true
        defaults.set(Date(), forKey: "updateLastChecked")
        let recent = UpdateController(settings: settings, defaults: defaults)
        recent.checkIfNeeded()
        #expect(recent.phase == .idle)
    }

    @Test func developmentBuildCannotInstall() {
        // 测试进程不是签名的 XStats.app
        let controller = UpdateController(settings: AppSettings(defaults: isolatedDefaults()))
        #expect(controller.installBlockedReason != nil)
    }

    @Test func manualDownloadUsesReleaseDMGThenGitHubReleases() {
        let controller = UpdateController(settings: AppSettings(defaults: isolatedDefaults()))
        // 没拿到清单时（检查失败、还没检查）落到 GitHub Releases，那里必须挂着 dmg
        #expect(controller.manualDownloadURL.absoluteString == "https://github.com/ysicing/xstats/releases/latest")

        let dmg = "https://c.ysicing.net/oss/apps/macOS/XStats/XStats-1.0.0-AppleSilicon.dmg"
        controller.showPreview(UpdateRelease(
            version: "1.0.0", build: "110", date: "2026-09-21", minimumSystem: "14.0",
            url: URL(string: "https://c.ysicing.net/oss/apps/macOS/XStats/XStats-1.0.0-AppleSilicon.zip")!,
            sha256: String(repeating: "a", count: 64), size: 123,
            dmg: URL(string: dmg)!, notes: ["示例"], changelog: nil))
        // 清单里有 dmg 时优先用它，用户拿到的就是这次提示的那一版
        #expect(controller.manualDownloadURL.absoluteString == dmg)
    }


}

@Suite struct DiagnosticsTests {
    @Test func redactsAddressesAndHome() {
        let text = "\(NSHomeDirectory())/Library/x 192.168.1.20 fe80::1c2b:3aff:fe4d:5e6f 2001:db8:0:0:1:2:3:4 ::1 a4:83:e7:12:34:56 12:30:45 版本 0.2.0"
        let redacted = DiagnosticsExporter.redact(text)
        #expect(redacted.hasPrefix("~/Library/x"))
        #expect(!redacted.contains("192.168.1.20"))
        #expect(!redacted.contains("a4:83:e7"))
        #expect(!redacted.contains("fe80::1c2b"))
        #expect(!redacted.contains("2001:db8"))
        #expect(!redacted.contains("::1"))
        #expect(redacted.contains("<MAC>"))
        #expect(redacted.contains("12:30:45"))
        #expect(redacted.contains("0.2.0"))
    }
}

@MainActor
@Suite struct ProcessRowTests {
    private func process(_ pid: Int32, _ name: String, bundle: String?, cpu: Double, memory: UInt64, owned: Bool = true) -> ProcessUsage {
        var usage = ProcessUsage(pid: pid, name: name, executablePath: nil, appBundlePath: bundle, cpu: cpu, memory: memory)
        usage.isOwned = owned
        usage.threads = 4
        return usage
    }

    @Test func groupsHelpersIntoTheirApp() {
        let rows = ProcessRowModel.grouped([
            process(10, "Safari", bundle: "/Applications/Safari.app", cpu: 10, memory: 100),
            process(11, "Safari Web Content", bundle: "/Applications/Safari.app", cpu: 5, memory: 300),
            process(12, "cloudd", bundle: nil, cpu: 1, memory: 50),
        ])
        #expect(rows.count == 2)
        let safari = rows.first { $0.count == 2 }
        #expect(safari?.cpu == 15)
        #expect(safari?.memory == 400)
        #expect(safari?.threads == 8)
        #expect(safari?.pid == nil)
    }

    @Test func blocksQuittingProtectedProcesses() {
        #expect(ProcessRowModel(process: process(1, "launchd", bundle: nil, cpu: 0, memory: 1, owned: false)).quitBlockedReason != nil)
        #expect(ProcessRowModel(process: process(getpid(), "XStats", bundle: nil, cpu: 0, memory: 1)).quitBlockedReason != nil)
        #expect(ProcessRowModel(process: process(99, "loginwindow", bundle: nil, cpu: 0, memory: 1)).quitBlockedReason != nil)
        #expect(ProcessRowModel(process: process(98, "Notes", bundle: nil, cpu: 0, memory: 1)).quitBlockedReason == nil)
    }

    @Test func narrowTablesDropColumns() {
        #expect(ProcessColumn.visible(forWidth: 2000) == ProcessColumn.allCases)
        #expect(ProcessColumn.visible(forWidth: 300) == [.name, .cpu, .memory, .user])
    }
}

@Suite struct DiagnosticsArchiveTests {
    @Test func writesZipWithSummaryAndLog() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: destination) }
        try DiagnosticsExporter.writeArchive(summary: "# 测试\n", to: destination)
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        listing.arguments = ["-1", destination.path]
        let pipe = Pipe()
        listing.standardOutput = pipe
        try listing.run()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        listing.waitUntilExit()
        #expect(names.contains("summary.txt"))
        #expect(names.contains("xstats.log"))
    }
}

@Suite struct TimedLineChartTests {
    @Test func positionsByTimeAndBreaksAtGaps() {
        let end = Date(timeIntervalSince1970: 1_000)
        let points = [
            TimedValue(date: end.addingTimeInterval(-70), value: 0.9),   // 超出时长，不画
            TimedValue(date: end.addingTimeInterval(-60), value: 0),
            TimedValue(date: end.addingTimeInterval(-55), value: 1),
            TimedValue(date: end.addingTimeInterval(-50), value: 0.5),
            TimedValue(date: end.addingTimeInterval(-10), value: 0.5),   // 与上一点隔了 40 秒（睡眠），断开
            TimedValue(date: end.addingTimeInterval(-5), value: 0.5),
            TimedValue(date: end, value: 0.5),
        ]
        let segments = TimedLineChart.segments(points, duration: 60, end: end, in: CGSize(width: 120, height: 40))
        #expect(segments.count == 2)
        #expect(segments[0].map(\.x) == [0, 10, 20])
        #expect(segments[1].map(\.x) == [100, 110, 120])
        // 0 在底、1 在顶，越大越靠上
        #expect(segments[0][0].y > segments[0][2].y && segments[0][2].y > segments[0][1].y)
        #expect(TimedLineChart.segments([], duration: 60, end: end, in: CGSize(width: 120, height: 40)).isEmpty)
    }
}

@Suite struct AlertTrackerTests {
    @Test func firesOnceAfterSustainAndRespectsCooldown() {
        var tracker = AlertTracker()
        func step(_ active: Bool, _ seconds: TimeInterval) -> Bool {
            tracker.update(isActive: active, now: Date(timeIntervalSince1970: seconds), sustain: 60, cooldown: 1800)
        }
        #expect(!step(true, 0))
        #expect(!step(true, 59))
        #expect(step(true, 60))
        // 同一段持续期内不重复
        #expect(!step(true, 600))
        // 恢复后再次出现，但还在冷却期
        #expect(!step(false, 700))
        #expect(!step(true, 800))
        #expect(!step(true, 900))
        // 冷却结束后同一段持续期仍可触发
        #expect(step(true, 1900))
    }

    @Test func briefSpikesDoNotFire() {
        var tracker = AlertTracker()
        var fired = false
        for second in stride(from: 0.0, to: 600, by: 30) {
            // 每 30 秒一升一降，从未持续满 60 秒
            fired = fired || tracker.update(isActive: Int(second) % 60 == 0, now: Date(timeIntervalSince1970: second),
                                            sustain: 60, cooldown: 1800)
        }
        #expect(!fired)
    }

    @Test func notificationTabsExist() {
        #expect(PanelTab.settings.contains(.settingsNotifications))
        #expect(Set(AlertKind.allCases.map(\.tab)).isSubset(of: Set(PanelTab.allCases)))
    }
}

@Suite struct HotKeyTests {
    @Test func eyeRestActionKeepsExistingCarbonIDs() throws {
        let calendar = try #require(HotKeyAction(rawValue: "openCalendar"))
        #expect(HotKeyAction.allCases.last == .startEyeRest)
        #expect(HotKeyAction.startEyeRest.carbonID == 6)
        #expect(calendar.carbonID == 5)
        #expect(HotKeyAction.toggleMainWindow.carbonID == 1)
        #expect(HotKeyAction.showProcesses.carbonID == 2)
        #expect(HotKeyAction.toggleKeepAwake.carbonID == 3)
        #expect(HotKeyAction.purgeMemory.carbonID == 4)
    }

    @Test func displaysAndValidates() {
        let hotKey = HotKey(keyCode: 1, modifiers: [.command, .option, .capsLock], key: "s")
        #expect(hotKey.display == "⌥⌘S")
        #expect(hotKey.isValid)
        #expect(!HotKey(keyCode: 1, modifiers: [.shift], key: "s").isValid)
        #expect(HotKey(keyCode: 49, modifiers: [.control], key: " ").display == "⌃空格")
    }

    @MainActor
    @Test func persistsBindings() {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.hotKeys[.toggleKeepAwake] = HotKey(keyCode: 40, modifiers: [.command, .shift], key: "k")
        settings.hotKeys[.openCalendar] = HotKey(keyCode: 37, modifiers: [.command, .option], key: "l")
        #expect(settings.hotKeys[.startEyeRest] == nil)
        let eyeRestKey = HotKey(keyCode: 14, modifiers: [.command, .option], key: "e")
        settings.hotKeys[.startEyeRest] = eyeRestKey
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.hotKeys[.startEyeRest] == eyeRestKey)
        let document = settings.exportDocument()
        settings.hotKeys = [:]
        settings.apply(document)
        #expect(settings.hotKeys[.startEyeRest] == eyeRestKey)
        #expect(reloaded.hotKeys[.toggleKeepAwake]?.display == "⇧⌘K")
        #expect(reloaded.hotKeys[.openCalendar]?.display == "⌥⌘L")
    }
}

@Suite struct FunctionKeyTests {
    @Test func namesFunctionKeys() {
        #expect(HotKey(keyCode: 0x7A, modifiers: [.command], key: "\u{F704}").display == "⌘F1")
    }
}

@MainActor
@Suite struct SettingsDocumentTests {
    @Test func exportsAndAppliesRoundTrip() {
        let source = AppSettings(defaults: isolatedDefaults())
        source.menuBarItems = [.gpu, .temperature]
        source.menuBarStyle = .ring
        source.styleOverrides = [.gpu: .pie]
        source.refreshSeconds = 5
        source.useFahrenheit = true
        source.hiddenPopoverSections = [.cpuHeatmap, .networkDNS]
        source.probeTarget = .aliyun
        source.enabledAlerts = [.cpuLoad]
        source.alertCPULoad = 90
        source.hotKeys = [.showProcesses: HotKey(keyCode: 35, modifiers: [.command, .option], key: "p")]
        source.panelTab = .thermal

        let document = source.exportDocument()
        let target = AppSettings(defaults: isolatedDefaults())
        target.panelTab = .cleaner
        target.apply(document)

        #expect(target.menuBarItems == [.gpu, .temperature])
        #expect(target.menuBarStyle == .ring)
        #expect(target.styleOverrides == [.gpu: .pie])
        #expect(target.refreshSeconds == 5)
        #expect(target.useFahrenheit)
        #expect(target.hiddenPopoverSections == [.cpuHeatmap, .networkDNS])
        #expect(target.probeTarget == .aliyun)
        #expect(target.enabledAlerts == [.cpuLoad])
        #expect(target.alertCPULoad == 90)
        #expect(target.hotKeys[.showProcesses]?.keyCode == 35)
        // 当前页签属于本机状态，不随文档走
        #expect(target.panelTab == .cleaner)
        #expect(target.exportDocument() == document)
    }

    @Test func skipsUnknownAndInvalidValues() {
        let settings = AppSettings(defaults: isolatedDefaults())
        var document = SettingsDocument()
        document.menuBarItems = ["cpu", "hologram"]
        document.menuBarStyle = "neon"
        document.refreshSeconds = 7
        document.probeTarget = "mars"
        document.language = "english"
        settings.apply(document)
        #expect(settings.menuBarItems == [.cpu])
        #expect(settings.menuBarStyle == .stacked)
        #expect(settings.refreshSeconds == 2)
        #expect(settings.probeTarget == .cloudflare)
        #expect(settings.language == .english)
        settings.language = .system
    }

    @Test func documentSurvivesJSONWithMissingFields() throws {
        let data = Data(#"{"schema":1,"refreshSeconds":3,"futureField":true}"#.utf8)
        let document = try JSONDecoder().decode(SettingsDocument.self, from: data)
        #expect(document.refreshSeconds == 3)
        #expect(document.menuBarItems == nil)
        let settings = AppSettings(defaults: isolatedDefaults())
        settings.apply(document)
        #expect(settings.refreshSeconds == 3)
        #expect(settings.menuBarItems == [.cpu, .memory, .network])
    }

    @Test func freshSettingsEqualDefaultDocument() {
        let settings = AppSettings(defaults: isolatedDefaults())
        #expect(settings.exportDocument() == AppSettings.defaultDocument())
        settings.colorizeHighLoad = true
        #expect(settings.exportDocument() != AppSettings.defaultDocument())
    }
}

@Suite struct ActivityRankingTests {
    @Test func smoothsAndKeepsRecentlyActiveEntries() {
        var ranking = ActivityRanking()
        ranking.update(["a": 10_000, "b": 100_000])
        #expect(ranking.ranked(limit: 5).map(\.id) == ["b", "a"])
        // b 突然安静，a 继续：b 的分数衰减但仍在榜上，a 慢慢追上
        for _ in 0..<3 { ranking.update(["a": 10_000]) }
        let entries = ranking.ranked(limit: 5)
        #expect(entries.map(\.id).contains("b"))
        #expect(entries.first?.id == "b")
        for _ in 0..<6 { ranking.update(["a": 10_000]) }
        #expect(ranking.ranked(limit: 5).first?.id == "a")
        // 长时间没有活动后从榜上移除
        for _ in 0..<40 { ranking.update([:]) }
        #expect(ranking.isEmpty)
    }

    @Test func limitsAndBreaksTiesByID() {
        var ranking = ActivityRanking()
        ranking.update(["x": 5_000, "y": 5_000, "z": 9_000])
        #expect(ranking.ranked(limit: 2).map(\.id) == ["z", "x"])
    }
}
