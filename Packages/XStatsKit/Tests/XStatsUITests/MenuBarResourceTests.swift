// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin
import Metrics
import SwiftUI
import Testing
@testable import XStatsUI

/// 显式设置输出路径才运行，避免普通测试每次启动长时间的真实硬件采样。
@MainActor
struct MenuBarResourceTests {
    private struct Phase: Codable {
        let name: String
        let elapsedSeconds: Double
        let cpuSeconds: Double
        let snapshots: Int
        let gpuSamples: Int
        let diskSamples: Int
        let processSamples: Int
        let sensorSamples: Int
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_MENU_RESOURCE_REPORT"] != nil))
    func realSamplingReturnsToIdleAfterClosingOverview() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["XSTATS_MENU_RESOURCE_REPORT"])
        let screen = try #require(NSScreen.main)
        let suite = "MenuBarResourceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil,
                             aiUsageProviders: [], aiQuotaProviders: [])
        model.settings.menuBarLayout = .iconOnly
        model.settings.menuBarItems = [.cpu, .memory, .network, .gpu, .disk, .temperature]
        model.settings.processesEnabled = true
        model.settings.refreshSeconds = 2
        let panel = StatusPanel(width: DS.Size.combinedPopoverWidth, minHeight: 100, maxHeight: 500) {
            CombinedPopoverView().environment(model)
        } measuring: {
            CombinedPopoverView().environment(model).environment(\.isSnapshot, true)
        }
        panel.onVisibilityChange = { model.isCombinedPopoverOpen = $0 }
        defer { panel.isPinned = false; panel.dismiss(); panel.close() }
        var samples: [MetricsSnapshot] = []
        await model.hub.update(model.demand)
        await model.hub.start(primeAllMetrics: false) { snapshot in
            model.store.apply(snapshot)
            samples.append(snapshot)
        }
        var report: [Phase] = []
        for (name, visible, paused) in [("idle", false, false), ("overview", true, false),
                                       ("closed", false, false), ("paused", false, true),
                                       ("resumed", false, false)] {
            if visible {
                panel.isPinned = true
                panel.present(below: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY,
                                           width: 20, height: 20), on: screen)
            } else {
                panel.isPinned = false
                panel.dismiss()
            }
            await model.hub.update(model.demand)
            await model.hub.setPaused(paused)
            samples.removeAll(keepingCapacity: true)
            let cpu = Self.cpuTime()
            let started = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(paused ? 2 : 6))
            // 忽略阶段切换边界上的第一条，断言实际发布的后续快照，而非只检查需求对象。
            let steady = Array(samples.dropFirst())
            if paused { #expect(steady.isEmpty) }
            else { #expect(steady.count >= 1) }
            #expect(steady.allSatisfy { $0.power == nil && $0.diskActivity == nil && $0.diskHealth == nil })
            if visible {
                #expect(steady.contains { $0.processes != nil })
                #expect(steady.contains { $0.sensors != nil })
            } else {
                #expect(steady.allSatisfy { $0.gpu == nil && $0.disk == nil && $0.processes == nil && $0.sensors == nil })
                #expect(!panel.isVisible)
                // NSPanel 初始化会提供一个空 NSView；只在真正打开再关闭后要求树已释放。
                if name == "closed" { #expect(panel.contentView == nil) }
            }
            report.append(Phase(name: name, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
                                cpuSeconds: Self.cpuTime() - cpu, snapshots: samples.count,
                                gpuSamples: samples.filter { $0.gpu != nil }.count,
                                diskSamples: samples.filter { $0.disk != nil }.count,
                                processSamples: samples.filter { $0.processes != nil }.count,
                                sensorSamples: samples.filter { $0.sensors != nil }.count))
        }
        await model.hub.stop()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
