// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
@testable import Metrics
import Testing
@testable import XStatsUI

struct IslandGeometryTests {
    @Test func notchContentClearsCameraAndUsesPhysicalGapCenter() {
        let geometry = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      visible: CGRect(x: 0, y: 0, width: 1512, height: 950),
                                      safeTop: 32, camera: 660...852)
        let frame = geometry.frame(for: .expanded)
        #expect(frame.maxY == 982)
        #expect(frame.midX == 756)
        #expect(geometry.contentInset == 32)
        #expect(frame.height == 32 + IslandPresentation.expanded.contentSize.height)
    }

    @Test func floatingCapsuleUsesVisibleFrameOnNegativeCoordinateScreen() {
        let geometry = IslandGeometry(screen: CGRect(x: -1920, y: -100, width: 1920, height: 1080),
                                      visible: CGRect(x: -1920, y: -100, width: 1920, height: 1055))
        let frame = geometry.frame(for: .expanded)
        #expect(frame.midX == -960)
        #expect(frame.maxY == 947)
        #expect(geometry.contentInset == 0)
        #expect(geometry.screen.contains(frame))
    }

    @Test func missingCameraGeometryFallsBackToFloatingCapsule() {
        let geometry = IslandGeometry(screen: CGRect(x: 0, y: 0, width: 800, height: 600),
                                      visible: CGRect(x: 0, y: 0, width: 800, height: 570), safeTop: 30)
        #expect(!geometry.hasNotch)
        #expect(geometry.frame(for: .collapsed).maxY == 562)
    }
}

struct IslandInteractionTests {
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
        let controller = IslandWindowController(appModel: app)
        defer { controller.stop() }
        let baseline = app.demand
        controller.start()
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

    @Test func switchingScenesAndSuspendingReleaseOnlyIslandDemand() {
        let app = appModel()
        let baseline = app.demand
        let controller = IslandWindowController(appModel: app)
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
        let controller = IslandWindowController(appModel: appModel())
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
        let controller = IslandWindowController(appModel: appModel())
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
        let controller = IslandWindowController(appModel: appModel())
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
}
