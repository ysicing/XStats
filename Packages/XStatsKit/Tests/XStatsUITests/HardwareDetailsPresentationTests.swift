// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin
import Localization
import SwiftUI
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
final class HardwareDetailsPresentationTests {
    private var suites: [String] = []

    deinit {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }
    private func model() throws -> AppModel {
        let suite = "HardwareDetailsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        suites.append(suite)
        settings.menuBarItems = []
        settings.historyEnabled = false
        settings.enabledAlerts = []
        return AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    }

    @Test func gpuDetailsDemandAndStaleSnapshotsRespectVisibilityAndEnergy() throws {
        let model = try model()
        model.settings.menuBarItems = [.gpu]
        #expect(model.demand.gpu && !model.demand.gpuFrequency && !model.demand.gpuPower)
        model.openPopover = .gpu
        #expect(model.demand.gpuFrequency && model.demand.gpuPower && !model.demand.power)
        var snapshot = MetricsSnapshot()
        snapshot.power = PowerReading(system: 20, gpu: 5, gpuFrequency: 900)
        model.handle(snapshot)
        #expect(model.store.power?.gpu == 5 && model.store.power?.gpuFrequency == 900)
        #expect(model.store.power?.system == nil && model.store.powerHistory.elements.isEmpty)
        model.settings.setModuleEnabled(.battery, false)
        model.applyMonitoringSettings()
        #expect(model.demand.gpuFrequency && !model.demand.gpuPower)
        #expect(model.store.power?.gpu == nil && model.store.power?.gpuFrequency == 900)
        model.settings.hiddenPopoverSections = [.gpuDetails]
        model.handle(snapshot)
        #expect(!model.demand.gpuFrequency && !model.demand.gpuPower && model.store.power == nil)
        model.settings.panelTab = .gpu
        model.isMainWindowVisible = true
        #expect(model.demand.gpuFrequency && !model.demand.gpuPower)
        model.settings.setModuleEnabled(.gpu, false)
        model.applyMonitoringSettings()
        #expect(!model.demand.gpuFrequency && model.store.power == nil)
        model.isMainWindowVisible = false
        model.settings.menuBarItems = []
        #expect(!model.demand.hasSamples)
    }

    @Test func diskCompositionBarUsesDisjointSegmentsAndFallsBack() throws {
        var disk = DiskUsage(volumeName: "Macintosh HD", total: 1000, available: 300, purgeable: 100)
        disk.breakdown = try #require(DiskBreakdown.compose(total: 1000, free: 200, purgeable: 100,
                                                           systemUsed: 100, dataUsed: 500, vmUsed: 50))
        let segments = DiskSegments.segments(disk)
        #expect(segments.map(\.id) == ["system", "data", "vm", "other", "purgeable", "free"])
        #expect(abs(segments.reduce(0) { $0 + $1.fraction } - 1) < 0.000001)
        disk.breakdown = nil
        #expect(DiskSegments.segments(disk).map(\.id) == ["used", "purgeable", "free"])
    }

    @Test(arguments: [(CGFloat(320), false), (CGFloat(600), true)])
    func detailsFitNarrowAndMainWindowInBothDirections(width: CGFloat, detail: Bool) throws {
        let model = try model()
        model.settings.hiddenPopoverSections = [.batteryApps, .batteryHistory, .batteryBluetooth, .batteryPower, .thermalSensors, .gpuHistory]
        var snapshot = MetricsSnapshot()
        snapshot.gpu = GPUUsage(name: "Apple M4 Max", utilization: 0.42, coreCount: 40,
                               rendererUtilization: 0.3, tilerUtilization: 0.2, memoryInUse: 4_294_967_296)
        snapshot.power = PowerReading(gpu: 4.2, gpuFrequency: 900)
        snapshot.battery = BatteryStatus(level: 0.8, isCharging: false, isPluggedIn: false, isFullyCharged: false,
                                         cycleCount: 123, health: 0.92, designCapacity: 9000, fullChargeCapacity: 8280,
                                         voltage: 12.34, amperage: -1.23)
        var disk = DiskUsage(volumeName: "Macintosh HD", total: 1000, available: 300, purgeable: 100)
        disk.breakdown = DiskBreakdown.compose(total: 1000, free: 200, purgeable: 100, systemUsed: 100, dataUsed: 500, vmUsed: 50)
        snapshot.disk = disk
        model.store.apply(snapshot)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for kind in ["gpu", "battery", "disk"] {
                let content = Group {
                    switch kind {
                    case "gpu": GPUPopover()
                    case "battery": BatteryPopover()
                    default: VStack { SegmentedBar(segments: DiskSegments.segments(disk)); DiskSegments.legend(disk) }
                    }
                }
                let host = NSHostingView(rootView: VStack { content }.environment(model).environment(\.isSnapshot, true)
                    .environment(\.isDetailPage, detail).environment(\.layoutDirection, direction).frame(width: width))
                let size = host.fittingSize
                #expect(abs(size.width - width) < 1 && size.height > 0 && size.height < 2200)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                if let path = ProcessInfo.processInfo.environment["XSTATS_HARDWARE_PREVIEW_DIR"] {
                    let folder = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(
                        "\(kind)-\(Int(width))-\(direction == .leftToRight ? "ltr" : "rtl").png"))
                }
                window.close()
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_GPU_RESOURCE_REPORT"] != nil))
    func gpuDetailsSamplingStopsAndRestartsWithFreshBaselines() async throws {
        let model = try model()
        var samples: [MetricsSnapshot] = []
        var report: [String: [String: Double]] = [:]
        var generation = 1000
        await model.hub.update(model.demand)
        await model.hub.start(primeAllMetrics: false) { snapshot in
            // 每个测量阶段独立代次，排除切换前已在主线程排队的旧快照。
            if snapshot.samplingGeneration == generation { samples.append(snapshot) }
        }
        for phase in ["idle", "open", "closed", "reopened", "paused", "resumed", "energy-off", "gpu-off"] {
            model.openPopover = ["open", "reopened", "paused", "resumed", "energy-off", "gpu-off"].contains(phase) ? .gpu : nil
            if phase == "energy-off" { model.settings.setModuleEnabled(.battery, false) }
            if phase == "gpu-off" { model.settings.setModuleEnabled(.gpu, false) }
            model.applyMonitoringSettings()
            generation += 1
            var demand = model.demand
            demand.generation = generation
            // 暂停阶段先停止旧循环，再开始计数；更新代次不得短暂重启一次采样。
            if phase == "paused" { await model.hub.setPaused(true) }
            samples.removeAll(keepingCapacity: true)
            await model.hub.update(demand)
            if phase != "paused" { await model.hub.setPaused(false) }
            var started = rusage(); getrusage(RUSAGE_SELF, &started)
            let wall = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(["idle", "closed", "paused", "gpu-off"].contains(phase) ? 3 : 5))
            if ["idle", "closed", "paused", "gpu-off"].contains(phase) { #expect(samples.isEmpty) }
            else {
                #expect(samples.contains { $0.gpu != nil })
                #expect(samples.contains { $0.power != nil })
                if ["open", "reopened", "resumed"].contains(phase) {
                    let firstPower = try #require(samples.first { $0.power != nil }?.power)
                    #expect(firstPower.gpuFrequency == nil)
                }
                if phase == "energy-off" { #expect(samples.allSatisfy { $0.power?.gpu == nil && $0.sensors == nil }) }
            }
            #expect(samples.allSatisfy { $0.power?.system == nil && $0.cpu == nil && $0.processes == nil })
            var ended = rusage(); getrusage(RUSAGE_SELF, &ended)
            let cpu = Double(ended.ru_utime.tv_sec - started.ru_utime.tv_sec + ended.ru_stime.tv_sec - started.ru_stime.tv_sec)
                + Double(ended.ru_utime.tv_usec - started.ru_utime.tv_usec + ended.ru_stime.tv_usec - started.ru_stime.tv_usec) / 1e6
            report[phase] = ["cpuSeconds": cpu, "wallSeconds": ProcessInfo.processInfo.systemUptime - wall,
                             "snapshots": Double(samples.count), "powerSamples": Double(samples.filter { $0.power != nil }.count),
                             "gpuFrequencySamples": Double(samples.filter { $0.power?.gpuFrequency != nil }.count)]
        }
        await model.hub.stop()
        let path = try #require(ProcessInfo.processInfo.environment["XSTATS_GPU_RESOURCE_REPORT"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: path))
    }
}
