// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
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
        #expect(expanded.maxY == screen.maxY - 22 - 24)
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
    func autoHiddenMenuBarStillHasClearance(presentation: IslandPresentation) {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let geometry = IslandGeometry(screen: screen, visible: screen)
        let frame = geometry.frame(for: presentation)
        #expect(frame.maxY <= screen.maxY - 22 - 8)
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

@MainActor
final class IslandWindowLifecycleTests {
    private var suites: [String] = []

    deinit {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func appModel() -> AppModel {
        let suite = "IslandTests.\(UUID())"
        suites.append(suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.menuBarItems = []
        settings.historyEnabled = false
        settings.enabledAlerts = []
        return AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
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
        #expect(app.demand == baseline)
        controller.selectScene(.system)
        #expect(controller.model.scene == .ai)
        app.settings.islandPreferences.setScene(.ai, visible: false)
        controller.syncWithPreferences()
        #expect(controller.model.scene == .focus)
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

    @Test func switchingScenesAndSuspendingReleaseOnlyIslandDemand() {
        let app = appModel()
        let baseline = app.demand
        let controller = IslandWindowController(appModel: app, fullscreenDetector: { _ in false })
        defer { controller.stop() }
        controller.start()
        controller.selectScene(.ai)
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
