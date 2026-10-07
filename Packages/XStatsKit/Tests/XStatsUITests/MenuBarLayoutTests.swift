// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
@testable import Metrics
import Observation
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct MenuBarLayoutTests {
    private func model(_ body: (AppModel, UserDefaults) throws -> Void) throws {
        let suite = "MenuBarLayoutTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil,
                             aiUsageProviders: [], aiQuotaProviders: [])
        try body(model, defaults)
    }

    @Test func iconOnlyPreservesItemsAndRoundTripsSettings() throws {
        try model { model, defaults in
            let settings = model.settings
            settings.menuBarItems = [.gpu, .disk, .temperature, .battery]
            settings.menuBarStyle = .ring
            settings.menuBarLayout = .iconOnly
            #expect(model.drawnMenuBarItems.isEmpty)
            #expect(Set(model.visibleMenuBarItems) == settings.menuBarItems)
            let document = settings.exportDocument()
            settings.menuBarLayout = .separate
            settings.apply(document)
            #expect(settings.menuBarLayout == .iconOnly)
            #expect(settings.menuBarStyle == .ring)
            #expect(settings.menuBarItems == [.gpu, .disk, .temperature, .battery])
            #expect(AppSettings(defaults: defaults).menuBarLayout == .iconOnly)
            settings.menuBarLayout = .combined
            #expect(model.drawnMenuBarItems == model.visibleMenuBarItems)
        }
    }

    @Test func overviewSamplingStartsOnOpenAndStopsOnClose() throws {
        try model { model, _ in
            model.settings.menuBarLayout = .iconOnly
            model.settings.menuBarItems = [.cpu, .memory, .gpu, .disk, .temperature, .battery]
            model.settings.processesEnabled = true
            model.settings.refreshSeconds = 5
            let idle = model.demand
            #expect(!idle.gpu && !idle.disk && !idle.battery && !idle.processes)
            #expect(idle.temperatures.isEmpty)
            #expect(model.bluetoothDemand == .off)
            for _ in 0..<10 {
                model.isCombinedPopoverOpen = true
                let visible = model.demand
                #expect(visible.interval == .seconds(1))
                #expect(visible.gpu && visible.disk && visible.battery && !visible.processes)
                #expect(!visible.systemProcesses && !visible.diskDetail && !visible.power && !visible.cpuFrequency)
                #expect(visible.temperatures.contains(.cpu))
                model.combinedPopoverTab = .disk
                #expect(model.demand.diskDetail)
                #expect(model.demand.processes && !model.demand.systemProcesses)
                // 展开磁盘详情后，其他总览行仍在屏幕中，必须继续更新摘要。
                #expect(model.demand.gpu && model.demand.battery)
                model.combinedPopoverTab = .gpu
                #expect(!model.demand.diskDetail && !model.demand.cpuFrequency)
                #expect(!model.demand.processes)
                model.combinedPopoverTab = nil
                #expect(!model.demand.processes)
                model.isCombinedPopoverOpen = false
                #expect(model.openPopover == nil)
                #expect(model.demand == idle)
                model.combinedPopoverTab = nil
            }
        }
    }

    @Test func disabledProcessesAndUnselectedMetricsAreNotCollectedForOverview() throws {
        try model { model, _ in
            model.settings.menuBarLayout = .iconOnly
            model.settings.menuBarItems = [.cpu, .memory]
            model.settings.processesEnabled = false
            model.isCombinedPopoverOpen = true
            #expect(!model.demand.processes && !model.demand.systemProcesses)
            #expect(!model.demand.gpu && !model.demand.disk && !model.demand.battery)
        }
    }

    @Test(arguments: [MenuBarLayout.combined, .iconOnly])
    func enablingProcessesDoesNotAddOverviewSampling(layout: MenuBarLayout) throws {
        try model { model, _ in
            model.settings.menuBarLayout = layout
            for item: MenuBarItem in [.cpu, .memory] {
                model.settings.menuBarItems = [item]
                model.settings.processesEnabled = false
                let idle = model.demand
                model.isCombinedPopoverOpen = true
                let overview = model.demand
                model.settings.processesEnabled = true
                #expect(model.demand == overview)
                #expect(!model.demand.processes && !model.demand.systemProcesses)
                // 只有展开 CPU / 内存详情才需要进程排行，收起后立即释放该需求。
                model.combinedPopoverTab = item
                #expect(model.demand.processes && !model.demand.systemProcesses)
                model.combinedPopoverTab = nil
                #expect(model.demand == overview)
                model.isCombinedPopoverOpen = false
                #expect(model.demand == idle)
            }
        }
    }

    @Test(arguments: [MenuBarLayout.combined, .iconOnly])
    func independentRefreshItemsPreserveBackgroundSampling(layout: MenuBarLayout) throws {
        try model { model, _ in
            model.settings.menuBarLayout = layout
            model.settings.refreshSeconds = 5
            model.settings.aiUsageEnabled = true
            let selections: [Set<MenuBarItem>] = [[], [.display], [.aiUsage], [.display, .aiUsage]]
            for items in selections {
                model.settings.menuBarItems = items
                let idle = model.demand
                #expect(idle.interval == .seconds(5))
                model.isCombinedPopoverOpen = true
                #expect(model.demand == idle)
                for item in items {
                    model.combinedPopoverTab = item
                    #expect(model.demand == idle)
                    if item == .display { #expect(model.displayControlsVisible) }
                }
                model.combinedPopoverTab = nil
                #expect(model.demand == idle)
                model.isCombinedPopoverOpen = false
                #expect(model.demand == idle)
                #expect(!model.displayControlsVisible)
            }
        }
    }

    @Test(arguments: [MenuBarLayout.combined, .iconOnly])
    func systemMetricsStillRefreshWhileDisplayDetailsAreExpanded(layout: MenuBarLayout) throws {
        try model { model, _ in
            model.settings.menuBarLayout = layout
            model.settings.refreshSeconds = 5
            var snapshot = MetricsSnapshot()
            snapshot.sensors = SensorReadings(temperatures: [], fans: [], fanCount: 1)
            model.store.apply(snapshot)
            for item: MenuBarItem in [.cpu, .memory, .network, .gpu, .disk, .temperature, .fan, .battery] {
                model.settings.menuBarItems = [.display, item]
                let idle = model.demand
                model.isCombinedPopoverOpen = true
                #expect(model.demand.interval == .seconds(1))
                model.combinedPopoverTab = .display
                #expect(model.demand.interval == .seconds(1))
                #expect(model.displayControlsVisible)
                model.isCombinedPopoverOpen = false
                model.combinedPopoverTab = nil
                #expect(model.demand == idle)
            }
        }
    }

    @Test func mainWindowDemandStillOverridesIndependentPanelRefresh() throws {
        try model { model, _ in
            model.settings.menuBarLayout = .iconOnly
            model.settings.menuBarItems = [.display]
            model.settings.refreshSeconds = 5
            model.isCombinedPopoverOpen = true
            model.combinedPopoverTab = .display
            model.isMainWindowVisible = true
            model.settings.panelTab = .cpu
            #expect(model.demand.interval == .seconds(1))
            model.settings.panelTab = .settingsGeneral
            #expect(model.demand.interval == .seconds(5))
            model.settings.processesEnabled = true
            model.settings.panelTab = .processes
            #expect(model.demand.interval == .seconds(2))
        }
    }

    @Test func compactOverviewHasNoHalfEmptyRowsAndExpandsInline() throws {
        try model { model, _ in
            model.settings.menuBarItems = [.cpu, .memory, .network, .disk, .battery]
            model.settings.processesEnabled = false
            let host = NSHostingView(rootView: CombinedPopoverView().environment(model).environment(\.isSnapshot, true))
            let collapsed = host.fittingSize
            #expect(abs(collapsed.width - DS.Size.combinedPopoverWidth) < 1)
            #expect(collapsed.height < 500)
            model.settings.processesEnabled = true
            let enabled = NSHostingView(rootView: CombinedPopoverView().environment(model)
                .environment(\.isSnapshot, true)).fittingSize
            #expect(abs(enabled.height - collapsed.height) < 1)
            model.combinedPopoverTab = .cpu
            let expanded = NSHostingView(rootView: CombinedPopoverView().environment(model).environment(\.isSnapshot, true)).fittingSize
            #expect(expanded.height > collapsed.height)
        }
    }

    @Test func unknownFansCanStillBeDiscoveredWithoutRewritingPreferences() throws {
        try model { model, _ in
            model.settings.menuBarItems = [.fan]
            #expect(!model.visibleMenuBarItems.contains(.fan))
            #expect(model.demand.fans)
            model.settings.menuBarLayout = .iconOnly
            #expect(!model.demand.fans)
            model.isCombinedPopoverOpen = true
            #expect(model.demand.fans)
            var snapshot = MetricsSnapshot()
            snapshot.sensors = SensorReadings(temperatures: [], fans: [], fanCount: 0)
            model.store.apply(snapshot)
            #expect(!model.demand.fans)
            #expect(model.settings.menuBarItems == [.fan])
        }
    }

    @Test func iconImageIgnoresLiveMetricsAndRetainsKeepAwakeIndicator() throws {
        try model { model, _ in
            model.settings.menuBarLayout = .iconOnly
            let before = MenuBarRenderer.image(for: model)
            var snapshot = MetricsSnapshot()
            snapshot.cpu = CPULoad(total: 0.95, user: 0.5, system: 0.45, perCore: [0.95], loadAverage: [1, 1, 1])
            model.store.apply(snapshot)
            let after = MenuBarRenderer.image(for: model)
            #expect(before.size == after.size)
            #expect(MenuBarRenderer.preview(before, dark: false).tiffRepresentation
                    == MenuBarRenderer.preview(after, dark: false).tiffRepresentation)
            var reading = MenuBarReading.sample
            let plain = MenuBarRenderer.image(reading: reading, items: [], style: { _ in .ring }, networkStyle: .dots,
                                             colorizeHighLoad: true, fahrenheit: false)
            reading.keepAwake = true
            let awake = MenuBarRenderer.image(reading: reading, items: [], style: { _ in .ring }, networkStyle: .dots,
                                             colorizeHighLoad: true, fahrenheit: false)
            #expect(plain.isTemplate && awake.isTemplate)
            #expect(awake.size.width > plain.size.width)
        }
    }

    @Test func iconOnlyReadingDoesNotObserveMetricChanges() async throws {
        let suite = "MenuBarLayoutTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil,
                             aiUsageProviders: [], aiQuotaProviders: [])
        model.settings.menuBarLayout = .iconOnly
        await confirmation(expectedCount: 0) { changed in
            withObservationTracking {
                _ = MenuBarReading(model: model, items: model.drawnMenuBarItems)
            } onChange: { changed() }
            var snapshot = MetricsSnapshot()
            snapshot.cpu = CPULoad(total: 0.9, user: 0.5, system: 0.4, perCore: [0.9], loadAverage: [1, 1, 1])
            snapshot.gpu = GPUUsage(name: "Fixture", utilization: 0.5, coreCount: 8)
            model.store.apply(snapshot)
        }
    }

    @Test func combinedPanelReopensAndKeepsAConsistentWidthAcrossDetails() async throws {
        let screen = try #require(NSScreen.main)
        let suite = "MenuBarLayoutTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil,
                             aiUsageProviders: [], aiQuotaProviders: [])
        model.settings.menuBarItems = [.cpu, .memory, .gpu, .disk, .network, .temperature, .battery]
        model.settings.menuBarLayout = .iconOnly
        let idle = model.demand
        let panel = StatusPanel(width: DS.Size.combinedPopoverWidth, minHeight: 100, maxHeight: 500) {
            CombinedPopoverView().environment(model)
        } measuring: {
            CombinedPopoverView().environment(model).environment(\.isSnapshot, true)
        }
        panel.isPinned = true
        panel.onVisibilityChange = { model.isCombinedPopoverOpen = $0 }
        defer { panel.close() }
        let anchor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 20, height: 20)
        for _ in 0..<5 {
            panel.isPinned = true
            model.combinedPopoverTab = nil
            panel.present(below: anchor, on: screen)
            let mounted = try #require(panel.contentView)
            for item: MenuBarItem? in [nil, .cpu, .network, .memory, nil] {
                model.combinedPopoverTab = item
                panel.refreshHeight()
                try await Task.sleep(for: .milliseconds(40))
                mounted.layoutSubtreeIfNeeded()
                #expect(panel.isVisible && model.isCombinedPopoverOpen)
                #expect(panel.contentView === mounted)
                #expect(abs(panel.frame.width - DS.Size.combinedPopoverWidth) < 1)
                #expect(panel.frame.height <= 501)
                #expect(model.openPopover == item)
                if item == nil {
                    // 离屏测高与真实布局保持一致，挂载后不能突然改变面板高度。
                    let natural = NSHostingView(rootView: CombinedPopoverView().environment(model)
                        .environment(\.isSnapshot, true)).fittingSize.height
                    // 高度回调会在下一轮主队列应用；等待该轮完成，避免并行测试负载下误读展开高度。
                    for _ in 0..<40 {
                        mounted.layoutSubtreeIfNeeded()
                        if abs(panel.frame.height - min(500, natural)) < 2 { break }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    #expect(abs(panel.frame.height - min(500, natural)) < 2)
                }
            }
            panel.isPinned = false
            panel.dismiss()
            #expect(!panel.isVisible && !model.isCombinedPopoverOpen)
            #expect(panel.contentView == nil)
            #expect(model.demand == idle)
        }
    }
}
