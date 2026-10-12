// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Metrics
import Testing
@testable import XStatsUI

/// 显式启用的真实硬件走查，普通测试不增加长时间采样；生成可复查的按阶段报告。
@MainActor
struct MonitoringResourceTests {
    private struct Phase: Codable {
        let name: String
        let cpuSeconds: Double
        let snapshots: Int
        let cpuSamples: Int
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_MONITORING_RESOURCE_REPORT"] != nil))
    func repeatedDisableStopsTheSamplingLoopAndReenableRestoresOnlySelectedMetrics() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["XSTATS_MONITORING_RESOURCE_REPORT"])
        let suite = "MonitoringResourceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.enabledMonitoringModules = []
        settings.historyEnabled = false
        settings.enabledAlerts = []
        settings.refreshSeconds = 2
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        var samples: [MetricsSnapshot] = []
        await model.hub.update(model.demand)
        await model.hub.start(primeAllMetrics: false) { snapshot in
            model.handle(snapshot)
            samples.append(snapshot)
        }
        var phases: [Phase] = []
        var lastActiveDemand: MetricsDemand?
        for (name, enabled) in [("disabled-at-start", false), ("cpu-only", true), ("disabled", false),
                                ("cpu-only-again", true), ("disabled-again", false)] {
            settings.setEnabled(.cpu, enabled)
            settings.setModuleEnabled(.cpu, enabled)
            model.applyMonitoringSettings()
            await model.hub.update(model.demand)
            if enabled { lastActiveDemand = model.demand }
            else if let lastActiveDemand {
                // 模拟 actor 排队中晚到的旧启用请求，不能在关闭后重启采样。
                await model.hub.update(lastActiveDemand)
            }
            samples.removeAll(keepingCapacity: true)
            let startedCPU = Self.cpuTime()
            try await Task.sleep(for: .seconds(3))
            if enabled {
                #expect(!samples.isEmpty)
                // CPU 首次读取用于建立计数基线，第二次起才有区间占用。
                #expect(samples.contains { $0.cpu != nil })
                #expect(samples.allSatisfy { $0.memory == nil && $0.network == nil
                    && $0.gpu == nil && $0.processes == nil && $0.sensors == nil && $0.power == nil })
            } else {
                #expect(samples.isEmpty, "无需求阶段不应发布空快照或继续采样")
                #expect(model.store.cpu == nil)
            }
            phases.append(Phase(name: name, cpuSeconds: Self.cpuTime() - startedCPU,
                                snapshots: samples.count, cpuSamples: samples.filter { $0.cpu != nil }.count))
        }
        await model.hub.stop()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(phases).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_BATTERY_POWER_RESOURCE_REPORT"] != nil))
    func batteryPowerSamplingStopsAfterRepeatedPageCloses() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["XSTATS_BATTERY_POWER_RESOURCE_REPORT"])
        let suite = "BatteryPowerResourceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.enabledMonitoringModules = [.battery]
        settings.menuBarItems = []
        settings.historyEnabled = false
        settings.enabledAlerts = []
        settings.panelTab = .battery
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        var samples: [MetricsSnapshot] = []
        var phases: [String: [String: Double]] = [:]
        await model.hub.update(model.demand)
        await model.hub.start(primeAllMetrics: false) { snapshot in
            model.handle(snapshot)
            samples.append(snapshot)
        }
        for (name, visible, monitoring, energy) in [("idle", false, true, false),
            ("power-only-before", true, true, false), ("battery-page", true, true, true),
            ("closed", false, true, false), ("battery-page-again", true, true, true),
            ("power-only-after", true, true, false), ("closed-again", false, true, false),
            ("battery-monitoring-off", true, false, true), ("closed-with-monitoring-off", false, false, false)] {
            let startedCPU = Self.cpuTime()
            let started = ProcessInfo.processInfo.systemUptime
            settings.setModuleEnabled(.battery, monitoring)
            // 功耗基线使用隐藏 App 能耗分区的弹窗；同样的功耗与电量需求、同样的采样频率。
            model.isMainWindowVisible = visible && energy
            model.openPopover = visible && !energy ? .battery : nil
            settings.hiddenPopoverSections = energy ? [] : [.batteryApps]
            model.applyMonitoringSettings()
            await model.hub.update(model.demand)
            // 需求交付完成后才统计，排除切换过程中已在主线程排队的上一阶段快照。
            samples.removeAll(keepingCapacity: true)
            // Hub 的一秒睡眠有 25% 容差，五秒采集点可能落在第六秒之后。
            try await Task.sleep(for: .seconds(visible && monitoring ? 7 : 3))
            if visible {
                if monitoring {
                    #expect(samples.contains { $0.power != nil })
                    if energy {
                        #expect((1...2).contains(samples.filter { $0.appEnergy != nil }.count))
                        #expect(samples.contains { $0.appEnergy?.interval != nil && $0.appEnergy?.isAvailable == true })
                    } else {
                        #expect(samples.allSatisfy { $0.appEnergy == nil } && model.store.appEnergy == nil)
                    }
                } else {
                    #expect(samples.contains { $0.battery != nil })
                    #expect(samples.allSatisfy { $0.power == nil && $0.appEnergy == nil })
                    #expect(model.store.battery != nil && model.store.power == nil)
                    #expect(model.store.powerHistory.elements.isEmpty)
                    #expect(model.demand.interval == .seconds(10))
                }
                #expect(samples.allSatisfy { $0.sensors == nil && $0.cpu == nil && $0.processes == nil })
            } else {
                #expect(samples.isEmpty)
                #expect(model.store.power == nil && model.store.powerHistory.elements.isEmpty && model.store.appEnergy == nil)
            }
            phases[name] = ["cpuSeconds": Self.cpuTime() - startedCPU,
                            "wallSeconds": ProcessInfo.processInfo.systemUptime - started,
                            "snapshots": Double(samples.count),
                            "batterySamples": Double(samples.filter { $0.battery != nil }.count),
                            "powerSamples": Double(samples.filter { $0.power != nil }.count),
                            "appEnergySamples": Double(samples.filter { $0.appEnergy != nil }.count)]
        }
        await model.hub.stop()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(phases).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_BASIC_INFORMATION_RESOURCE_REPORT"] != nil))
    func disabledInformationPagesNeverStartContinuousMonitoring() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["XSTATS_BASIC_INFORMATION_RESOURCE_REPORT"])
        let suite = "BasicInformationResourceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.enabledMonitoringModules = []
        settings.menuBarItems = []
        settings.historyEnabled = false
        settings.enabledAlerts = Set(AlertKind.allCases)
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        var snapshots = 0
        await model.hub.update(model.demand)
        await model.hub.start(primeAllMetrics: false) { _ in snapshots += 1 }
        var phases: [String: [String: Double]] = [:]
        for tab in [PanelTab.cpu, .gpu, .memory, .disk, .network, .thermal, .disk, .network] {
            model.isMainWindowVisible = true
            settings.panelTab = tab
            model.applyMonitoringSettings()
            await model.hub.update(model.demand)
            snapshots = 0
            let startedCPU = Self.cpuTime()
            if tab == .disk { await model.store.refreshDiskCapacity() }
            if tab == .network { await model.network.refreshDetails(basicOnly: true) }
            try await Task.sleep(for: .seconds(2))
            #expect(snapshots == 0 && !model.demand.hasSamples && settings.activeAlerts.isEmpty)
            #expect(model.store.processes.isEmpty && model.store.powerHistory.elements.isEmpty)
            #expect(model.network.processes.isEmpty && model.network.probes.elements.isEmpty)
            phases["\(phases.count)-\(tab.rawValue)"] = ["cpuSeconds": Self.cpuTime() - startedCPU,
                                                     "snapshots": Double(snapshots)]
            model.isMainWindowVisible = false
            await model.hub.update(model.demand)
        }
        try await Task.sleep(for: .seconds(2))
        #expect(snapshots == 0 && !model.demand.hasSamples)
        await model.hub.stop()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(phases).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
