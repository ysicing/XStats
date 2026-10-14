// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import SMC
import Testing
@testable import Metrics
@testable import XStatsUI

/// 在 macOS 15 的图形会话运行同一组用例，才能验收该系统的真实 DisplayLink 行为。
@MainActor
struct StartupRenderingTests {
    @Test(arguments: [PanelTab.overview, .system, .battery, .cpu, .memory, .network, .gpu, .disk, .thermal, .settingsAbout],
          [false, true])
    func restoredPageRendersAndCanReachUpdates(page: PanelTab, energyEnabled: Bool) async throws {
        _ = NSApplication.shared
        _ = try #require(NSScreen.main)
        let suite = "XStats.StartupRenderingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.enabledMonitoringModules = Set(MonitoringModule.allCases)
        settings.setModuleEnabled(.battery, energyEnabled)
        settings.aiUsageEnabled = false
        settings.historyEnabled = false
        settings.panelTab = page
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [],
                             networkCacheDefaults: defaults)
        let controller = MainWindowController(model: model)
        defer { controller.close() }
        var snapshot = MetricsSnapshot()
        snapshot.cpu = CPULoad(total: 0.3, user: 0.2, system: 0.1, perCore: [0.2, 0.4], loadAverage: [1, 2, 3])
        snapshot.gpu = GPUUsage(name: "Fixture", utilization: 0.3, coreCount: 8)
        snapshot.memory = MemoryUsage(total: 1_000, app: 300, wired: 100, compressed: 50, cached: 200,
                                      swapUsed: 0, swapTotal: 0, pressure: .normal, uncompressed: 100,
                                      swapInBytes: 0, swapOutBytes: 0)
        snapshot.network = NetworkRate(downloadBytesPerSecond: 1_500_000, uploadBytesPerSecond: 20_000,
                                       totalDownloaded: 10_000_000, totalUploaded: 100_000)
        snapshot.battery = BatteryStatus(level: 0.8, isCharging: false, isPluggedIn: true,
                                        isFullyCharged: false, minutesRemaining: nil, cycleCount: 100, health: 0.9)
        snapshot.disk = DiskUsage(volumeName: "Fixture", total: 1_000_000, available: 600_000)
        snapshot.processes = [ProcessUsage(pid: 999_999, name: "Fixture", executablePath: nil,
                                          appBundlePath: nil, cpu: 12, memory: 1024)]
        snapshot.sensors = SensorReadings(temperatures: [
            TemperatureSummary(group: .cpu, average: 48, maximum: 62, sensorCount: 8)
        ], fans: [FanState(id: 0, current: 1_800, minimum: 0, maximum: 6_000,
                          target: 1_800, isManual: false)], fanCount: 1)
        model.store.apply(snapshot)

        for _ in 0..<2 {
            // nil 沿用保存的页面，与 applicationDidFinishLaunching 的窗口入口一致。
            settings.panelTab = page
            controller.show(tab: nil)
            let window = try #require(controller.nsWindow)
            #expect(window.isVisible && model.isMainWindowVisible)
            try await Task.sleep(for: .milliseconds(200))
            snapshot.cpu?.total = 0.7
            model.store.apply(snapshot)
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            #expect(settings.panelTab == page)

            // 验证从恢复页进入升级页；不检查、下载或安装更新。
            controller.show(tab: .settingsAbout)
            try await Task.sleep(for: .milliseconds(200))
            #expect(settings.panelTab == .settingsAbout)
            #expect(window.isVisible && window.contentView != nil)
            controller.close()
            #expect(!model.isMainWindowVisible && !controller.isVisible)
        }

        if let path = ProcessInfo.processInfo.environment["XSTATS_STARTUP_REPORT_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                "macOS15": ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15,
                "page": page.rawValue, "energyEnabled": energyEnabled, "openCloseCycles": 2,
                "scope": "MainWindowController rendering; not full process startup"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
                to: directory.appendingPathComponent("\(page.rawValue)-energy-\(energyEnabled).json"))
        }
    }
}
