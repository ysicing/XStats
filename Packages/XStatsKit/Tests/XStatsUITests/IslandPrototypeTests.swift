// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import AIUsage
import Foundation
import Observation
import SwiftUI
@testable import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct IslandGeometryTests {
    @Test(arguments: [IslandPresentation.collapsed, .preview, .expanded])
    func attachedTopStaysFixedAndContentClearsCamera(presentation: IslandPresentation) {
        let screen = CGRect(x: -1512, y: -982, width: 1512, height: 982)
        let geometry = IslandGeometry(screen: screen, visible: screen, safeTop: 32, camera: -852 ... -660)
        var preferences = IslandPreferences()
        preferences.placement = .attached
        preferences.topInset = 32
        let frame = geometry.frame(for: presentation, preferences: preferences, compactWidth: 120)
        let content = IslandSilhouette.contentFrame(in: frame, placement: .attached, topClearance: geometry.attachedTopClearance)
        #expect(frame.maxY == screen.maxY)
        #expect(frame.midX == -756)
        #expect(frame.width >= 192 + 2 * IslandSilhouette.shoulder)
        #expect(content.maxY == screen.maxY - 32)
        #expect(content.height == presentation.contentSize.height)
        #expect(screen.contains(frame) && frame.contains(content))
    }

    @Test func attachedContentClearsVisibleMenuBarAndSmallScreenBottom() {
        let screen = CGRect(x: 200, y: 100, width: 800, height: 250)
        let geometry = IslandGeometry(screen: screen, visible: CGRect(x: 200, y: 120, width: 800, height: 200))
        var preferences = IslandPreferences()
        preferences.placement = .attached
        let frame = geometry.frame(for: .expanded, preferences: preferences)
        let content = IslandSilhouette.contentFrame(in: frame, placement: .attached, topClearance: geometry.attachedTopClearance)
        #expect(frame.maxY == screen.maxY && frame.minY == geometry.visible.minY)
        #expect(content.maxY == geometry.visible.maxY)
        #expect(frame.contains(content))
    }

    @Test(arguments: [IslandPresentation.collapsed, .preview, .expanded])
    func attachedWithoutNotchDoesNotReserveAnAutoHiddenMenuBar(presentation: IslandPresentation) {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let geometry = IslandGeometry(screen: screen, visible: screen)
        var preferences = IslandPreferences()
        preferences.placement = .attached
        let frame = geometry.frame(for: presentation, preferences: preferences, compactWidth: 120)
        let content = IslandSilhouette.contentFrame(in: frame, placement: .attached, topClearance: geometry.attachedTopClearance)
        #expect(frame.maxY == screen.maxY)
        #expect(frame.height == presentation.contentSize.height)
        #expect(content.maxY == frame.maxY)
        #expect(content.height == frame.height)
        #expect(screen.contains(frame))
    }

    @Test func attachedSilhouetteConnectsToTopWithStableAnimationTopology() {
        var topology: [CGPathElementType] = []
        for size in [CGSize(width: 144, height: 54), CGSize(width: 360, height: 126), CGSize(width: 420, height: 342)] {
            let bounds = CGRect(origin: .zero, size: size)
            let path = IslandSilhouette.path(in: bounds, placement: .attached)
            #expect(path.boundingBoxOfPath == bounds)
            #expect(path.contains(CGPoint(x: bounds.midX, y: bounds.maxY - 1)))
            #expect(!path.contains(CGPoint(x: 1, y: bounds.midY)))
            #expect(path.contains(CGPoint(x: bounds.midX, y: 1)))
            var elements: [CGPathElementType] = []
            path.applyWithBlock { elements.append($0.pointee.type) }
            if topology.isEmpty { topology = elements }
            else { #expect(elements == topology) }
        }
    }

    @Test func oldPreferencesPreserveValuesWhenPlacementIsMissing() throws {
        var preferences = IslandPreferences()
        preferences.enabled = true
        preferences.scene = .focus
        preferences.topInset = 24
        preferences.display = "external"
        preferences.placement = .attached
        let encoded = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(IslandPreferences.self, from: encoded) == preferences)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "placement")
        let migrated = try JSONDecoder().decode(IslandPreferences.self, from: JSONSerialization.data(withJSONObject: object))
        preferences.placement = .floating
        #expect(migrated == preferences)
        #expect(try JSONDecoder().decode(IslandPreferences.self, from: Data("{}".utf8)) == IslandPreferences())
    }

    @Test func contentPreferencesMigrateAndKeepAVisibleSelection() throws {
        var preferences = IslandPreferences()
        preferences.scene = .focus
        let encoded = try JSONEncoder().encode(preferences)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "scenes")
        object.removeValue(forKey: "systemMetrics")
        let old = try JSONDecoder().decode(IslandPreferences.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old == preferences)
        preferences.setScene(.focus, visible: false)
        #expect(preferences.scene == .system)
        preferences.setScene(.ai, visible: false)
        preferences.setScene(.battery, visible: false)
        preferences.setScene(.system, visible: false)
        #expect(preferences.scenes == [.system])
        preferences.setMetric(.cpu, visible: false)
        #expect(preferences.primaryMetric == .memory)
        preferences.setMetric(.memory, visible: false)
        preferences.setMetric(.temperature, visible: false)
        preferences.setMetric(.power, visible: false)
        #expect(preferences.systemMetrics == [.power])
        #expect(try JSONDecoder().decode(IslandPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
        preferences.scenes = []
        preferences.systemMetrics = []
        #expect(preferences.normalized.scenes == [.system])
        #expect(preferences.normalized.systemMetrics == [.cpu])
    }

    @Test func displaySelectionSurvivesDisconnectClamshellAndReconnect() {
        let external = IslandDisplayChoice(id: "external", name: "Display", isBuiltIn: false)
        let builtIn = IslandDisplayChoice(id: "internal", name: "Display", isBuiltIn: true)
        let secondary = IslandDisplayChoice(id: "second", name: "Display", isBuiltIn: false)
        #expect(IslandDisplayChoice.preferredID(savedID: "", displays: [external, builtIn]) == builtIn.id)
        #expect(IslandDisplayChoice.preferredID(savedID: external.id, displays: [external, builtIn]) == external.id)
        #expect(IslandDisplayChoice.preferredID(savedID: external.id, displays: [builtIn]) == builtIn.id)
        #expect(IslandDisplayChoice.preferredID(savedID: external.id, displays: [external, builtIn]) == external.id)
        #expect(IslandDisplayChoice.preferredID(savedID: builtIn.id, displays: [external, secondary]) == external.id)
        #expect(IslandDisplayChoice.preferredID(savedID: "", displays: [external, secondary]) == external.id)
        #expect(IslandDisplayChoice.preferredID(savedID: "", displays: []) == nil)
    }

    @Test func customDimensionsAndGapKeepTheMenuBarClear() {
        let screen = CGRect(x: -800, y: -600, width: 800, height: 600)
        let geometry = IslandGeometry(screen: screen, visible: screen)
        var preferences = IslandPreferences()
        preferences.size = .custom
        preferences.customWidth = 560
        preferences.customHeight = 400
        preferences.topInset = 24
        let expanded = geometry.frame(for: .expanded, preferences: preferences)
        #expect(expanded.width == 560 && expanded.height == 400)
        #expect(expanded.maxY == screen.maxY - 24)
        let collapsed = geometry.frame(for: .collapsed, preferences: preferences, compactWidth: 128)
        #expect(collapsed.width == 128 && collapsed.height == 32)
        #expect(collapsed.maxY == expanded.maxY)
    }

    @Test func compactWidthFollowsContentWithinBounds() {
        let timer = IslandCompactLayout.width(for: "25:00")
        let quota = IslandCompactLayout.width(for: "Codex 75%")
        #expect(timer >= 120 && timer < 160)
        #expect(quota >= timer)
        #expect(IslandCompactLayout.width(for: String(repeating: "W", count: 200)) == 260)
    }

    @Test func notchContentClearsMenuBarAndUsesPhysicalGapCenter() {
        let geometry = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      visible: CGRect(x: 0, y: 0, width: 1512, height: 950),
                                      safeTop: 32, camera: 660...852)
        let frame = geometry.frame(for: .expanded)
        #expect(frame.maxY == 942)
        #expect(frame.midX == 756)
        #expect(frame.height == IslandPresentation.expanded.contentSize.height)
    }

    @Test func floatingCapsuleUsesVisibleFrameOnNegativeCoordinateScreen() {
        let geometry = IslandGeometry(screen: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
                                      visible: CGRect(x: -1920, y: -100, width: 1920, height: 1055))
        let frame = geometry.frame(for: .expanded)
        #expect(frame.midX == -960)
        #expect(frame.maxY == 947)
        #expect(geometry.screen.contains(frame))
    }

    @Test func missingCameraGeometryFallsBackToFloatingCapsule() {
        let geometry = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 800, height: 600),
                                      visible: CGRect(x: 0, y: 0, width: 800, height: 570), safeTop: 30)
        #expect(!geometry.hasNotch)
        #expect(geometry.frame(for: .collapsed).maxY == 562)
    }

    @Test(arguments: [IslandPresentation.collapsed, .preview, .expanded])
    func autoHiddenMenuBarOnlyKeepsFloatingGap(presentation: IslandPresentation) {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let geometry = IslandGeometry(screen: screen, visible: screen)
        let frame = geometry.frame(for: presentation)
        #expect(frame.maxY == screen.maxY - 8)
        #expect(screen.contains(frame))
    }

    @Test(arguments: [IslandPresentation.collapsed, .preview, .expanded])
    func autoHiddenNotchedMenuBarStillHasClearance(presentation: IslandPresentation) {
        let screen = CGRect(x: 100, y: -982, width: 1512, height: 982)
        let geometry = IslandGeometry(screen: screen, visible: screen, safeTop: 32, camera: 760...952)
        let frame = geometry.frame(for: presentation)
        #expect(frame.maxY <= screen.maxY - 32 - 8)
        #expect(frame.midX == 856)
        #expect(frame.width == presentation.contentSize.width)
    }
}

struct IslandInteractionTests {
    @Test func clickingModeNeverOpensOnHover() {
        var interaction = IslandInteraction()
        let ticket = interaction.enter()
        interaction.finishHover(generation: ticket, opening: .click)
        #expect(interaction.presentation == .collapsed)
    }

    @Test func hoverExpansionClosesOnlyAfterLeavingAndCanBePinnedByClick() {
        var interaction = IslandInteraction()
        let ticket = interaction.enter()
        interaction.finishHover(generation: ticket, opening: .hoverExpand)
        #expect(interaction.presentation == .expanded)
        let exit = interaction.leave()
        #expect(interaction.presentation == .expanded)
        interaction.enter()
        interaction.finishClose(generation: exit)
        #expect(interaction.presentation == .expanded)
        let latestExit = interaction.leave()
        interaction.expand()
        interaction.finishClose(generation: latestExit)
        #expect(interaction.presentation == .expanded)
    }

    @Test func hoverExpansionClosesAtTheCurrentDeadline() {
        var interaction = IslandInteraction()
        let ticket = interaction.enter()
        interaction.finishHover(generation: ticket, opening: .hoverExpand)
        let exit = interaction.leave()
        interaction.finishClose(generation: exit)
        #expect(interaction.presentation == .collapsed)
    }

    @Test func leavingDoesNotCollapseAnExplicitExpansion() {
        var interaction = IslandInteraction()
        interaction.expand()
        interaction.leave()
        #expect(interaction.presentation == .expanded)
    }

    @Test func delayedHoverCannotReplaceClickOrDismissal() {
        var interaction = IslandInteraction()
        let hover = interaction.enter()
        interaction.expand()
        interaction.finishHover(generation: hover)
        #expect(interaction.presentation == .expanded)
        interaction.collapse()
        interaction.finishHover(generation: hover)
        #expect(interaction.presentation == .collapsed)
    }

    @Test func hoverPreviewClosesOnLeaving() {
        var interaction = IslandInteraction()
        let hover = interaction.enter()
        interaction.finishHover(generation: hover)
        #expect(interaction.presentation == .preview)
        interaction.leave()
        #expect(interaction.presentation == .collapsed)
    }
}

// 控制器订阅的是进程级通知中心（NotificationCenter/NSWorkspace/DistributedNotificationCenter，
// object 均为 nil），并共享 NSStatusBar 与 NSApp.currentEvent。并发用例在 await 处交错时，
// 一个用例投递的空间切换等通知会被其他用例仍在运行的控制器收到，必须串行执行。
@Suite(.serialized)
@MainActor
final class IslandWindowLifecycleTests {
    private var suites: [String] = []

    deinit {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func appModel(quotaProviders: [any AIQuotaProvider] = []) -> AppModel {
        let suite = "IslandTests.\(UUID())"
        suites.append(suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.menuBarItems = []
        settings.historyEnabled = false
        settings.enabledAlerts = []
        settings.aiUsageEnabled = true
        let app = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: quotaProviders)
        var snapshot = MetricsSnapshot()
        snapshot.hasInternalBattery = true
        app.store.apply(snapshot)
        return app
    }

    @Test(arguments: [0.02, 0.29, 1.0])
    func collapsedWidthFitsTheNativeLabel(load: Double) {
        _ = NSApplication.shared
        let app = appModel()
        var snapshot = MetricsSnapshot()
        snapshot.cpu = CPULoad(total: load, user: load, system: 0, perCore: [], loadAverage: [])
        app.store.apply(snapshot)
        let model = IslandModel()
        let view = IslandView(model: model, appModel: app, selectScene: { _ in }, expand: {}, collapse: {}, stop: {})
        let host = NSHostingView(rootView: view.fixedSize(horizontal: true, vertical: false))
        let idealWidth = host.fittingSize.width
        #expect(IslandCompactLayout.width(for: view.compactValue) >= idealWidth)
    }

    @Test func preferencesRestoreAndOldBackupsLeaveThemAlone() throws {
        let app = appModel()
        let settings = app.settings
        #expect(!settings.islandPreferences.enabled)
        settings.islandPreferences.enabled = true
        settings.islandPreferences.scene = .focus
        settings.islandPreferences.opening = .click
        settings.islandPreferences.placement = .attached
        settings.islandPreferences.scenes = [.system, .focus]
        settings.islandPreferences.systemMetrics = [.memory, .power]
        settings.islandPreferences.display = "saved-display"
        settings.islandPreferences.size = .custom
        settings.islandPreferences.customWidth = 999
        settings.islandPreferences.hoverDelay = -1
        let restored = AppSettings(defaults: settings.audioDefaults)
        #expect(restored.islandPreferences.enabled)
        #expect(restored.islandPreferences.scene == .focus)
        #expect(restored.islandPreferences.scenes == [.system, .focus])
        #expect(restored.islandPreferences.systemMetrics == [.memory, .power])
        #expect(restored.islandPreferences.placement == .attached)
        #expect(restored.islandPreferences.display == "saved-display")
        #expect(restored.islandPreferences.customWidth == 600)
        #expect(restored.islandPreferences.hoverDelay == 0.1)
        restored.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
        #expect(restored.islandPreferences.enabled)
        let document = restored.exportDocument()
        #expect(document.islandPreferences?.display == "")
        #expect(document.islandPreferences?.systemMetrics == [.memory, .power])
        #expect(document.islandPreferences?.scenes == [.system, .focus])
        restored.apply(document)
        #expect(restored.islandPreferences.display == "saved-display")
    }

    @Test func enablingAndFullscreenHidingRestoreDemandWithoutChangingFeatures() {
        let app = appModel()
        let baseline = app.demand
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.syncWithPreferences()
        #expect(!controller.isRunning && controller.panel == nil)
        app.settings.islandPreferences.enabled = true
        controller.syncWithPreferences()
        #expect(controller.isRunning && app.demand.cpu)
        controller.setFullscreen(true)
        #expect(controller.panel == nil && app.demand == baseline)
        controller.setFullscreen(false)
        #expect(controller.panel?.isVisible == true && app.demand.cpu)
        app.settings.islandPreferences.enabled = false
        controller.syncWithPreferences()
        #expect(!controller.isRunning && controller.panel == nil && app.demand == baseline)
        #expect(app.settings.isModuleEnabled(.cpu))
    }

    @Test func hoverExpansionNeverTakesKeyFocusAndPendingExitCannotReopenAfterStop() async throws {
        let app = appModel()
        app.settings.islandPreferences.enabled = true
        app.settings.islandPreferences.opening = .hoverExpand
        app.settings.islandPreferences.hoverDelay = 0.1
        app.settings.islandPreferences.closeDelay = 0.1
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.syncWithPreferences()
        controller.entered()
        try await Task.sleep(for: .milliseconds(160))
        #expect(controller.model.presentation == .expanded)
        #expect(controller.panel?.isKeyWindow == false)
        controller.exited()
        controller.stop()
        try await Task.sleep(for: .milliseconds(160))
        #expect(!controller.isRunning && controller.panel == nil)
        #expect(app.islandScene == nil)
    }
    @Test func islandReadsNewSnapshotsAndDoesNotInventMissingValues() {
        let app = appModel()
        let view = IslandView(model: IslandModel(), appModel: app, selectScene: { _ in }, expand: {}, collapse: {}, stop: {})
        #expect(view.cpuValue == "—")
        var snapshot = MetricsSnapshot()
        snapshot.cpu = CPULoad(total: 0.31, user: 0.2, system: 0.11, perCore: [], loadAverage: [])
        app.store.apply(snapshot)
        let first = view.cpuValue
        snapshot.cpu = CPULoad(total: 0.67, user: 0.5, system: 0.17, perCore: [], loadAverage: [])
        app.store.apply(snapshot)
        #expect(view.cpuValue != first)
        app.settings.setModuleEnabled(.cpu, false)
        #expect(view.cpuValue != first)
        #expect(view.cpuValue != (0.67).formatted(.percent))
        #expect(app.aiUsage.todayTokens == nil)
    }

    @Test func confirmedAbsentBatteryFallsBackAndReleasesOnlyIslandBatteryDemand() async throws {
        let app = appModel()
        app.settings.setModuleEnabled(.battery, false)
        app.settings.islandPreferences.scene = .battery
        app.settings.islandPreferences.scenes = [.battery]
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        controller.expand()
        #expect(controller.model.scene == .battery)
        var snapshot = MetricsSnapshot()
        snapshot.hasInternalBattery = false
        app.store.apply(snapshot)
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.panel != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.isRunning && controller.panel == nil && app.islandScene == nil)
        #expect(controller.model.presentation == .collapsed)
        #expect(!app.demand.battery)
        #expect(app.settings.islandPreferences.scene == .battery)
        #expect(app.settings.islandPreferences.scenes == [.battery])
        #expect(app.store.battery == nil && app.store.hasInternalBattery == false)
        app.settings.setModuleEnabled(.battery, true)
        #expect(!app.demand.power && !app.demand.battery)
        // 其他界面的电池基础信息需求仍按原有规则管理。
        app.openPopover = .battery
        #expect(app.demand.battery)
    }

    @Test func absentBatteryAtStartupSkipsAutomaticFocusAndPowerNotices() {
        let app = appModel()
        app.settings.setModuleEnabled(.battery, false)
        app.settings.islandPreferences.scene = .battery
        app.settings.islandPreferences.automaticFocus = true
        var snapshot = MetricsSnapshot()
        snapshot.hasInternalBattery = false
        app.store.apply(snapshot)
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        #expect(controller.model.scene == .system)
        #expect(!app.demand.battery)
        controller.receiveBattery(BatteryStatus(level: 0.5, isCharging: false, isPluggedIn: false, isFullyCharged: false), revision: 1)
        controller.receiveBattery(BatteryStatus(level: 0.5, isCharging: true, isPluggedIn: true, isFullyCharged: false), revision: 2)
        #expect(controller.model.powerNotice == nil)
        #expect(!app.demand.battery)
    }

    @Test func allUnavailableContentReleasesPanelAndRestoresWithoutPolling() async throws {
        let app = appModel()
        app.settings.islandPreferences.scenes = [.ai]
        app.settings.islandPreferences.scene = .ai
        let saved = app.settings.islandPreferences
        let baseline = app.demand
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        controller.expand()
        #expect(controller.panel != nil && app.islandScene == .ai)
        for _ in 0..<3 {
            app.settings.aiUsageEnabled = false
            let hiddenDeadline = ContinuousClock.now + .seconds(2)
            while controller.panel != nil, ContinuousClock.now < hiddenDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(controller.isRunning && controller.isSuspended && controller.panel == nil)
            #expect(app.islandScene == nil && app.demand == baseline)
            #expect(app.settings.islandPreferences == saved)
            controller.expand()
            #expect(controller.panel == nil)
            app.settings.aiUsageEnabled = true
            let visibleDeadline = ContinuousClock.now + .seconds(2)
            while controller.panel == nil, ContinuousClock.now < visibleDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(controller.panel?.isVisible == true && app.islandScene == .ai)
            #expect(controller.model.presentation == .collapsed)
        }
    }

    @Test func unavailablePrimaryUsesNextEnabledMetricWithoutEnablingModules() async throws {
        let app = appModel()
        app.settings.islandPreferences.scenes = [.system]
        app.settings.islandPreferences.systemMetrics = [.cpu, .memory]
        app.settings.setModuleEnabled(.cpu, false)
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        #expect(app.islandPreferences.primaryMetric == .memory)
        #expect(!app.demand.cpu && app.demand.memory)
        #expect(IslandReading(scene: .system, appModel: app).context == IslandSystemMetric.memory.title)
        app.settings.setModuleEnabled(.memory, false)
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.panel != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.panel == nil && !app.demand.cpu && !app.demand.memory)
        #expect(app.settings.islandPreferences.systemMetrics == [.cpu, .memory])
        app.settings.setModuleEnabled(.cpu, true)
        let restored = ContinuousClock.now + .seconds(2)
        while controller.panel == nil, ContinuousClock.now < restored { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.panel != nil && app.demand.cpu && !app.demand.memory)
    }

    @Test func unknownBatteryReadPreservesKnownPresenceAndLastReading() {
        let store = MetricsStore(readBattery: false)
        #expect(store.hasInternalBattery == nil)
        var snapshot = MetricsSnapshot()
        snapshot.battery = BatteryStatus(level: 0.5, isCharging: false, isPluggedIn: false, isFullyCharged: false)
        store.apply(snapshot)
        store.apply(MetricsSnapshot())
        #expect(store.hasInternalBattery == true && store.battery?.level == 0.5)
        snapshot = MetricsSnapshot()
        snapshot.hasInternalBattery = false
        store.apply(snapshot)
        store.apply(MetricsSnapshot())
        #expect(store.hasInternalBattery == false && store.battery == nil)
    }

    @Test func batteryDemandUsesBasicSamplingAndIsReleasedWhenHidden() {
        let app = appModel()
        app.settings.setModuleEnabled(.battery, false)
        app.settings.islandPreferences.scene = .battery
        let baseline = app.demand
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        #expect(app.demand.battery && app.demand.interval == .seconds(10))
        #expect(!app.demand.power && app.demand.temperatures.isEmpty && !app.demand.appEnergy)
        controller.expand()
        #expect(app.demand.battery && app.demand.interval == .seconds(10))
        controller.setLocked(true)
        #expect(app.demand == baseline)
        controller.setLocked(false)
        #expect(app.demand.battery)
        controller.stop()
        #expect(app.demand == baseline)
    }

    @Test func powerNoticesExpireRestoreAndDoNotInterruptOrReplayAfterHiding() async throws {
        let app = appModel()
        app.settings.setModuleEnabled(.battery, false)
        app.settings.islandPreferences.scene = .ai
        let controller = IslandWindowController(appModel: app, powerNoticeDuration: .milliseconds(100), fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        #expect(app.demand.battery && !app.demand.power)
        var snapshot = MetricsSnapshot()
        var battery = BatteryStatus(level: 0.5, isCharging: false, isPluggedIn: false, isFullyCharged: false)
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == nil)
        battery.isPluggedIn = true
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == .connected && controller.model.scene == .ai)
        try await Task.sleep(for: .milliseconds(160))
        #expect(controller.model.powerNotice == nil && controller.model.scene == .ai)
        battery.isPluggedIn = false
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == .disconnected)
        controller.expand()
        #expect(controller.model.powerNotice == nil)
        battery.isPluggedIn = true
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == nil && controller.model.presentation == .expanded)
        controller.collapse()
        #expect(controller.model.powerNotice == nil)
        battery.isPluggedIn = false
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        controller.setSleeping(true)
        #expect(controller.panel == nil && controller.model.powerNotice == nil && !app.demand.battery)
        controller.setSleeping(false)
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == nil)
        controller.stop()
        try await Task.sleep(for: .milliseconds(160))
        #expect(controller.panel == nil && controller.model.powerNotice == nil)
    }

    @Test func restoringVisibilityIgnoresCachedReadsBeforeTheFirstNewBatterySnapshot() {
        let app = appModel()
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        var snapshot = MetricsSnapshot()
        var battery = BatteryStatus(level: 0.5, isCharging: false, isPluggedIn: false, isFullyCharged: false)
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        controller.setFullscreen(true)
        // 恢复时设置变化、摘要读取或隐藏前排队的回调仍可能读到旧缓存。
        controller.setFullscreen(false)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        battery.isPluggedIn = true
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == nil)
        battery.isPluggedIn = false
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == .disconnected)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == .disconnected)
    }

    @Test(arguments: [false, true])
    func resetDeadlineInvalidatesQuotaWithoutFetchingOrStealingExpandedScene(expanded: Bool) async throws {
        let app = appModel(quotaProviders: [IslandExpiryQuota()])
        app.settings.aiUsageEnabled = true
        app.settings.aiUsageSources = [.codex]
        app.settings.islandPreferences.automaticFocus = true
        await app.aiUsage.refresh()
        defer { app.aiUsage.stop() }
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        #expect(controller.model.scene == .ai)
        let attempt = app.aiUsage.lastAttemptAt
        if expanded { controller.expand() }
        try await Task.sleep(for: .seconds(1.2))
        #expect(controller.model.scene == (expanded ? .ai : .system))
        #expect(IslandReading(scene: .ai, appModel: app).quotaAccount?.primary(at: Date()) == nil)
        #expect(app.aiUsage.lastAttemptAt == attempt)
    }

    @Test func automaticFocusKeepsExpandedPageAndResolvesOnCollapse() async throws {
        let app = appModel()
        app.settings.islandPreferences.enabled = true
        app.settings.islandPreferences.automaticFocus = true
        app.settings.islandPreferences.scene = .ai
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        #expect(app.demand.battery)
        controller.expand()
        var snapshot = MetricsSnapshot()
        snapshot.battery = BatteryStatus(level: 0.05, isCharging: false, isPluggedIn: false, isFullyCharged: false)
        app.store.apply(snapshot)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.model.scene == .ai)
        controller.collapse()
        #expect(controller.model.scene == .battery)
        #expect(app.settings.islandPreferences.scene == .ai)
        controller.expand()
        controller.selectScene(.system)
        controller.syncWithPreferences()
        #expect(controller.model.scene == .system)
        #expect(app.demand.cpu)
        controller.setSleeping(true)
        #expect(app.islandScene == nil)
        #expect(!app.demand.battery)
    }

    @Test func systemDemandTracksVisibleContentAndRespectsDisabledModules() {
        let app = appModel()
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        let baseline = app.demand
        controller.start()
        #expect(controller.panel?.level == .floating)
        #expect(app.demand.cpu)
        #expect(app.demand.memory == baseline.memory)
        controller.expand()
        #expect(app.demand.memory)
        #expect(app.demand.power)
        #expect(app.demand.temperatures.contains(.cpu))
        app.settings.setModuleEnabled(.cpu, false)
        app.settings.setModuleEnabled(.memory, false)
        app.settings.setModuleEnabled(.battery, false)
        #expect(!app.demand.cpu)
        #expect(!app.demand.memory)
        #expect(!app.demand.power)
        #expect(app.demand.temperatures.isEmpty)
    }

    @Test(arguments: IslandSystemMetric.allCases)
    func onlySelectedMetricsAddDemand(metric: IslandSystemMetric) {
        let app = appModel()
        app.settings.islandPreferences.systemMetrics = [metric]
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        let baseline = app.demand
        controller.start()
        for expanded in [false, true] {
            if expanded { controller.expand() }
            let demand = app.demand
            #expect(demand.cpu == (metric == .cpu))
            #expect(demand.memory == (metric == .memory))
            #expect(demand.power == (metric == .power))
            #expect(demand.temperatures.contains(.cpu) == (metric == .temperature))
            #expect(demand.interval == .seconds(1))
        }
        let reading = IslandReading(scene: .system, appModel: app)
        #expect(reading.compactValue == metric.title + " " + reading.value(for: metric))
        app.settings.setModuleEnabled(.cpu, false)
        app.settings.setModuleEnabled(.memory, false)
        app.settings.setModuleEnabled(.battery, false)
        #expect(!app.demand.cpu && !app.demand.memory && !app.demand.power && app.demand.temperatures.isEmpty)
        controller.stop()
        #expect(app.demand.interval == baseline.interval)
    }

    @Test(arguments: IslandSystemMetric.allCases)
    func moduleToggleDropsIslandReadingsAndRestoresOnlyRequestedMetrics(metric: IslandSystemMetric) {
        let app = appModel()
        app.settings.islandPreferences.systemMetrics = [metric]
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        controller.expand()
        var snapshot = MetricsSnapshot()
        snapshot.cpu = CPULoad(total: 0.5, user: 0.3, system: 0.2, perCore: [], loadAverage: [])
        snapshot.memory = MemoryUsage(total: 100, app: 30, wired: 10, compressed: 10, cached: 10,
            swapUsed: 0, swapTotal: 0, pressure: .normal, uncompressed: 10, swapInBytes: 0, swapOutBytes: 0)
        snapshot.sensors = SensorReadings(temperatures: [.init(group: .cpu, average: 50, maximum: 55, sensorCount: 1)], fans: [])
        snapshot.power = PowerReading(system: 20)
        app.store.apply(snapshot)
        let reading = IslandReading(scene: .system, appModel: app)
        let enabledValue = reading.value(for: metric)
        let module: MonitoringModule = metric == .cpu ? .cpu : metric == .memory ? .memory : .battery
        app.settings.setModuleEnabled(module, false)
        app.applyMonitoringSettings()
        #expect(reading.value(for: metric) != enabledValue)
        #expect(!app.demand.cpu && !app.demand.memory && !app.demand.power && app.demand.temperatures.isEmpty)
        #expect(app.demand.battery && !app.demand.appEnergy)
        #expect(app.settings.islandPreferences.primaryMetric == metric)
        app.settings.setModuleEnabled(module, true)
        #expect(reading.value(for: metric) == "—")
        #expect(app.demand.cpu == (metric == .cpu))
        #expect(app.demand.memory == (metric == .memory))
        #expect(app.demand.power == (metric == .power))
        #expect(app.demand.temperatures.contains(.cpu) == (metric == .temperature))
        app.store.apply(snapshot)
        #expect(reading.value(for: metric) == enabledValue)
        #expect(controller.model.scene == .system && controller.model.presentation == .expanded)
    }

    @Test(arguments: [false, true])
    func disablingAIReleasesAutomaticFocusAndEnablingRestoresSelectedAccount(expanded: Bool) async throws {
        let app = appModel(quotaProviders: [IslandToggleQuota()])
        app.settings.aiUsageEnabled = true
        app.settings.aiUsageSources = [.codex]
        app.settings.islandPreferences.automaticFocus = true
        app.settings.islandPreferences.quotaAccountID = AIProviderID.codex.rawValue
        await app.aiUsage.refresh()
        defer { app.aiUsage.stop() }
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        #expect(controller.model.scene == .ai)
        if expanded { controller.expand() }
        let reading = IslandReading(scene: .ai, appModel: app)
        #expect(reading.quotaAccount != nil)
        app.settings.aiUsageEnabled = false
        app.aiUsage.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(reading.quotaAccounts.isEmpty && reading.quotaAccount == nil)
        #expect(app.aiUsage.todayTokens == nil)
        #expect(controller.model.scene == .system)
        #expect(app.settings.islandPreferences.quotaAccountID == AIProviderID.codex.rawValue)
        app.settings.aiUsageEnabled = true
        await app.aiUsage.refresh()
        try await Task.sleep(for: .milliseconds(50))
        #expect(reading.quotaAccount?.id == AIProviderID.codex.rawValue)
        #expect(controller.model.scene == (expanded ? .system : .ai))
        // 单个来源关闭也不能继续显示其缓存；恢复来源不改变固定账号偏好。
        app.settings.aiUsageSources = []
        #expect(reading.quotaAccount == nil)
        app.settings.aiUsageSources = [.codex]
        #expect(reading.quotaAccount?.id == AIProviderID.codex.rawValue)
    }

    @Test func restModuleToggleStopsActionsAndPreservesIslandSelection() async throws {
        let app = appModel()
        app.settings.islandPreferences.scene = .focus
        app.settings.restEnabled = true
        app.rest.sync()
        app.rest.setRunning(true)
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop(); app.rest.stop() }
        controller.start()
        controller.expand()
        let reading = IslandReading(scene: .focus, appModel: app)
        let runningValue = reading.compactValue
        app.settings.restEnabled = false
        app.rest.sync()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.model.scene == .system)
        #expect(!app.rest.isRunning && app.rest.secondsRemaining == 0)
        #expect(reading.compactValue != runningValue)
        app.rest.startPause()
        #expect(!app.rest.isRunning)
        app.settings.restEnabled = true
        app.rest.sync()
        try await Task.sleep(for: .milliseconds(50))
        app.rest.startPause()
        #expect(app.rest.isRunning && app.rest.secondsRemaining > 0)
        #expect(controller.model.scene == .focus && controller.model.presentation == .expanded)
        #expect(app.settings.islandPreferences.scene == .focus)
    }

    @Test func deselectingBatteryClearsPowerNoticeAndReenablingStartsWithFreshBaseline() {
        let app = appModel()
        app.settings.islandPreferences.enabled = true
        app.settings.islandPreferences.scene = .ai
        app.settings.setModuleEnabled(.battery, false)
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        var snapshot = MetricsSnapshot()
        var battery = BatteryStatus(level: 0.5, isCharging: false, isPluggedIn: false, isFullyCharged: false)
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        battery.isPluggedIn = true
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == .connected)
        app.settings.islandPreferences.setScene(.battery, visible: false)
        controller.syncWithPreferences()
        #expect(!app.demand.battery && controller.model.powerNotice == nil)
        battery.isPluggedIn = false
        snapshot.battery = battery
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == nil)
        app.settings.islandPreferences.setScene(.battery, visible: true)
        controller.syncWithPreferences()
        #expect(app.demand.battery && !app.settings.isModuleEnabled(.battery))
        #expect(!app.demand.power && app.demand.temperatures.isEmpty && !app.demand.appEnergy)
        app.store.apply(snapshot)
        controller.receiveBattery(battery, revision: app.store.batteryRevision)
        #expect(controller.model.powerNotice == nil)
    }

    @Test func hidingTheCurrentSceneFallsBackAndReleasesItsDemand() {
        let app = appModel()
        app.settings.islandPreferences.enabled = true
        let baseline = app.demand
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.syncWithPreferences()
        #expect(app.demand.cpu)
        app.settings.islandPreferences.setScene(.system, visible: false)
        controller.syncWithPreferences()
        #expect(controller.model.scene == .ai)
        #expect(app.demand.battery && app.demand.interval == .seconds(10) && !app.demand.cpu)
        controller.selectScene(.system)
        #expect(controller.model.scene == .ai)
        app.settings.islandPreferences.setScene(.ai, visible: false)
        controller.syncWithPreferences()
        #expect(controller.model.scene == .battery)
        #expect(!app.settings.restEnabled)
        app.settings.islandPreferences.setScene(.system, visible: true)
        controller.selectScene(.system)
        #expect(app.demand.cpu)
        app.settings.islandPreferences.systemMetrics = [.power]
        controller.syncWithPreferences()
        #expect(!app.demand.cpu && app.demand.power)
        controller.setLocked(true)
        #expect(app.demand == baseline)
    }

    @Test func selectingTheCurrentTabDoesNotRewritePreferences() {
        let app = appModel()
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        withObservationTracking {
            _ = app.settings.islandPreferences
        } onChange: {
            Issue.record("Repeated selection must not invalidate Island preferences")
        }
        controller.selectScene(controller.model.scene)
    }

    @Test func rapidExpandedTabSwitchesKeepTheLastSelectionAndWindowSize() async throws {
        let app = appModel()
        app.settings.islandPreferences.enabled = true
        app.settings.restEnabled = true
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        controller.expand()
        try await Task.sleep(for: .milliseconds(220))
        let frame = try #require(controller.panel?.frame)
        let attempt = app.aiUsage.lastAttemptAt
        for scene in [IslandScene.ai, .focus, .system, .focus, .ai, .system, .ai] {
            controller.selectScene(scene)
            controller.syncWithPreferences()
            controller.panel?.contentView?.layoutSubtreeIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.model.scene == .ai && controller.model.presentation == .expanded)
        #expect(app.islandScene == .ai && app.islandExpanded)
        #expect(controller.panel?.frame == frame)
        #expect(app.aiUsage.lastAttemptAt == attempt)
        #expect(AppSettings(defaults: app.settings.audioDefaults).islandPreferences.scene == .ai)
    }

    @Test func switchingScenesAndSuspendingReleaseOnlyIslandDemand() {
        let app = appModel()
        app.settings.islandPreferences.enabled = true
        let baseline = app.demand
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        controller.selectScene(.ai)
        #expect(app.demand.battery && app.demand.interval == .seconds(10) && !app.demand.cpu)
        app.settings.islandPreferences.setScene(.battery, visible: false)
        controller.syncWithPreferences()
        #expect(app.demand == baseline)
        controller.selectScene(.system)
        #expect(app.demand.cpu)
        controller.setLocked(true)
        #expect(app.demand == baseline)
        controller.setLocked(false)
        #expect(app.demand.cpu)
        controller.stop()
        #expect(app.demand == baseline)
    }

    @Test func restCountdownUpdatesWhileIslandIsItsOnlyVisibleConsumer() async throws {
        let suite = "IslandRestTests.\(UUID())"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        var now: UInt64 = 0
        let rest = RestController(settings: settings, localDefaults: defaults, sharedDefaults: nil, clock: { now })
        defer { rest.stop() }
        rest.sync()
        rest.setRunning(true)
        rest.setIslandVisible(true)
        let initial = rest.secondsRemaining
        now += 2_000_000_000
        try await Task.sleep(for: .milliseconds(1250))
        #expect(rest.secondsRemaining == initial - 2)
        rest.setIslandVisible(false)
        let hidden = rest.secondsRemaining
        now += 2_000_000_000
        try await Task.sleep(for: .milliseconds(1250))
        #expect(rest.secondsRemaining == hidden)
    }

    @Test func expansionPublishesContentAfterItsContainerHasTheFinalSize() throws {
        let app = appModel()
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        let screen = try #require(controller.panel?.screen)
        let geometry = IslandGeometry(screen)
        let target = geometry.frame(for: .expanded, preferences: app.islandPreferences)
        let expected = IslandSilhouette.contentFrame(in: target, placement: app.islandPreferences.placement,
                                                    topClearance: geometry.attachedTopClearance).size
        withObservationTracking {
            _ = controller.model.presentation
        } onChange: {
            MainActor.assumeIsolated {
                // 发布展开内容前应完成容器定位，避免在收起尺寸上同步重建再重新布局。
                #expect(controller.panel?.contentView?.subviews.first?.frame.size == expected)
            }
        }
        controller.expand()
        #expect(controller.model.presentation == .expanded)
    }

    @Test func repeatedExpansionAndPreferenceSyncPreserveTheRunningTransition() throws {
        let app = appModel()
        app.settings.islandPreferences.enabled = true
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        controller.expand()
        let date = controller.model.date
        controller.expand()
        #expect(controller.model.date == date)
        let mask = try #require(controller.panel?.contentView?.layer?.mask)
        let animating = mask.animation(forKey: "island-shape") != nil
        controller.syncWithPreferences()
        #expect((mask.animation(forKey: "island-shape") != nil) == animating)
        controller.collapse()
        let closing = mask.animation(forKey: "island-shape") != nil
        controller.syncWithPreferences()
        #expect((mask.animation(forKey: "island-shape") != nil) == closing)
    }

    @Test func stoppingDuringExpansionReleasesWindowAndPreventsLateReopening() async throws {
        let controller = IslandWindowController(appModel: appModel(), fullscreenDetector: { _ in false })
        controller.start()
        weak var oldPanel = controller.panel
        #expect(oldPanel?.isVisible == true)
        controller.expand()
        controller.stop()
        #expect(controller.panel == nil)
        // AppKit may retain a closed NSWindow until its autorelease pool drains.
        // The synchronous contract is removal of its expensive hosted content and visibility.
        #expect(oldPanel?.contentView == nil)
        #expect(oldPanel?.isVisible != true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.panel == nil)
        #expect(!controller.isRunning)
        #expect(oldPanel?.contentView == nil)
    }

    @Test func islandVisibilityDoesNotResumeASuspendedRestSession() async throws {
        let suite = "IslandSuspendedRestTests.\(UUID())"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        var now: UInt64 = 0
        let rest = RestController(settings: settings, localDefaults: defaults, sharedDefaults: nil, clock: { now })
        defer { rest.stop() }
        rest.sync()
        rest.setRunning(true)
        rest.setMenuBarVisible(true)
        rest.setIslandVisible(true)
        rest.suspend()
        let remaining = rest.secondsRemaining
        now = 2_000_000_000
        rest.setIslandVisible(false)
        try await Task.sleep(for: .milliseconds(1250))
        #expect(rest.secondsRemaining == remaining)
        rest.setIslandVisible(true)
        #expect(rest.secondsRemaining == remaining)
        now = UInt64(remaining + 1) * 1_000_000_000
        rest.sync()
        #expect(rest.completedToday == 0)
    }

    @Test func unlockDoesNotResumeWhileSystemIsStillSleeping() {
        let controller = IslandWindowController(appModel: appModel(), fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        controller.setLocked(true)
        controller.setSleeping(true)
        #expect(controller.panel == nil)
        controller.setLocked(false)
        #expect(controller.panel == nil)
        controller.setSleeping(false)
        #expect(controller.panel?.isVisible == true)
        #expect(controller.model.presentation == .collapsed)
    }

    @Test func interruptedTransitionsKeepTheLatestFrameAndRestartOnlyOnce() async throws {
        let screen = try #require(NSScreen.main)
        let controller = IslandWindowController(appModel: appModel(), fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        let first = try #require(controller.panel)
        controller.expand()
        controller.collapse()
        controller.expand()
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.model.presentation == .expanded)
        // This test machine may have another built-in display; all valid targets have the same height.
        #expect(first.frame.height >= IslandPresentation.expanded.contentSize.height)
        #expect(first.frame.height <= IslandPresentation.expanded.contentSize.height + max(32, screen.safeAreaInsets.top))
        controller.setLocked(true)
        #expect(first.contentView == nil)
        controller.setLocked(false)
        let resumed = try #require(controller.panel)
        controller.start()
        #expect(controller.panel === resumed)
        #expect(controller.model.presentation == .expanded)
    }

    @Test(arguments: [true, false])
    func spaceChangesRestoreTopPositionEvenWhenFullscreenStateIsUnchanged(hideInFullscreen: Bool) async throws {
        let app = appModel()
        app.settings.islandPreferences.placement = .attached
        app.settings.islandPreferences.hideInFullscreen = hideInFullscreen
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        let panel = try #require(controller.panel)
        let expected = panel.frame
        // 模拟 WindowServer 在切换空间时移动辅助窗口；全屏布尔值仍是 false。
        panel.setFrameOrigin(CGPoint(x: expected.minX, y: expected.minY - 600))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(panel.frame == expected)
        #expect(controller.model.presentation == .collapsed)
        #expect(app.islandScene == .system)
        controller.stop()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(250))
        #expect(controller.panel == nil)
    }

    @Test func spaceRefreshHidesRestoresAndCannotReopenAfterStop() async throws {
        let app = appModel()
        app.settings.islandPreferences.placement = .attached
        var fullscreen = false
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in fullscreen })
        defer { controller.stop() }
        let baseline = app.demand
        controller.start()
        let expected = try #require(controller.panel).frame
        fullscreen = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.panel == nil && app.demand == baseline)
        fullscreen = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.panel?.frame == expected && app.demand.cpu)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        controller.stop()
        try await Task.sleep(for: .milliseconds(250))
        #expect(controller.panel == nil && app.demand == baseline)
    }

    @Test func switchingPlacementCancelsOldTransitionAndPreservesMenuPriority() async throws {
        let screen = try #require(NSScreen.main)
        let app = appModel()
        app.settings.islandPreferences.enabled = true
        app.settings.islandPreferences.display = IslandPreferences.displayKey(screen)
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.syncWithPreferences()
        controller.expand()
        app.settings.islandPreferences.placement = .attached
        controller.syncWithPreferences()
        let panel = try #require(controller.panel)
        let attached = panel.frame
        #expect(controller.model.presentation == .collapsed)
        #expect(attached.maxY == screen.frame.maxY)
        let canvas = try #require(panel.contentView)
        let content = try #require(canvas.subviews.first)
        #expect(content.frame.maxY <= canvas.bounds.maxY - IslandGeometry(screen).attachedTopClearance)
        #expect(panel.level == .floating && panel.level.rawValue < NSWindow.Level.mainMenu.rawValue)
        try await Task.sleep(for: .milliseconds(250))
        #expect(panel.frame == attached)
        controller.expand()
        app.settings.islandPreferences.placement = .floating
        controller.syncWithPreferences()
        let floating = panel.frame
        #expect(floating.maxY < screen.frame.maxY - IslandGeometry(screen).topClearance)
        try await Task.sleep(for: .milliseconds(250))
        #expect(panel.frame == floating)
        #expect(content.frame == canvas.bounds)
        controller.stop()
        #expect(panel.contentView == nil)
    }
}

private struct IslandExpiryQuota: AIQuotaProvider {
    let id = AIProviderID.codex
    func fetch() async throws -> AIQuotaSnapshot {
        .init(provider: id, windows: [.init(kind: .session, usedPercent: 100, resetsAt: Date().addingTimeInterval(0.8))], fetchedAt: Date())
    }
}

private struct IslandToggleQuota: AIQuotaProvider {
    let id = AIProviderID.codex
    func fetch() async throws -> AIQuotaSnapshot {
        .init(provider: id, windows: [.init(kind: .session, usedPercent: 100,
            resetsAt: Date().addingTimeInterval(600), duration: 18_000)], fetchedAt: Date())
    }
}
