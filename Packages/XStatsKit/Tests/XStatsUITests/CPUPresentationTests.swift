// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Metrics
@testable import XStatsUI

struct CPUPresentationTests {
    @Test func superAndPerformanceGroupsHaveDistinctWorkloadRoles() {
        let superCore = CPUCluster(id: 0, name: "Fixture S", coreIndices: [12, 13], kind: .superCore)
        let performance = CPUCluster(id: 1, name: "Fixture P", coreIndices: [0, 1], kind: .performance)
        let topology = CPUTopology(brand: "Fixture S/P", logicalCores: 4, clusters: [superCore, performance])
        #expect(superCore.workloadRole(in: topology) == .heavy)
        #expect(performance.workloadRole(in: topology) == .parallel)
    }

    @Test func traditionalPerformanceAndEfficiencyRolesRemainDistinct() {
        let performance = CPUCluster(id: 0, name: "Fixture P", coreIndices: [2, 3], kind: .performance)
        let efficiency = CPUCluster(id: 1, name: "Fixture E", coreIndices: [0, 1], kind: .efficiency)
        let topology = CPUTopology(brand: "Fixture P/E", logicalCores: 4, clusters: [performance, efficiency])
        #expect(performance.workloadRole(in: topology) == .heavy)
        #expect(efficiency.workloadRole(in: topology) == .light)
    }

    @Test func genericGroupDoesNotInventWorkloadRole() {
        let generic = CPUCluster(id: 0, name: "Fixture", coreIndices: [0, 1], kind: .unknown)
        let topology = CPUTopology(brand: "Fixture", logicalCores: 2, clusters: [generic])
        #expect(generic.workloadRole(in: topology) == nil)
    }

    @Test func unfamiliarHigherTierDoesNotMakePerformanceTierTheFastest() {
        let future = CPUCluster(id: 0, name: "Future", coreIndices: [2, 3], kind: .unknown)
        let performance = CPUCluster(id: 1, name: "P", coreIndices: [0, 1], kind: .performance)
        let topology = CPUTopology(brand: "Fixture", logicalCores: 4, clusters: [future, performance])
        #expect(performance.workloadRole(in: topology) == .parallel)
        #expect(future.workloadRole(in: topology) == nil)
    }

    @Test(arguments: [(ProcessInfo.ThermalState.nominal, Tone.primary), (.fair, .warning),
                      (.serious, .error), (.critical, .error)])
    func mapsThermalStateToTone(_ state: ProcessInfo.ThermalState, _ tone: Tone) {
        #expect(Tone.forThermalState(state) == tone)
    }

    @MainActor @Test func thermalStateChangesPropagateWithoutChangingCPUUtilization() {
        let store = MetricsStore()
        var snapshot = MetricsSnapshot()
        snapshot.cpu = CPULoad(total: 0.5, user: 0.3, system: 0.2, perCore: [0.5], loadAverage: [])
        snapshot.cpu?.thermalState = .nominal
        store.apply(snapshot)
        #expect(store.cpu?.thermalState == .nominal)
        snapshot.cpu?.thermalState = .serious
        store.apply(snapshot)
        #expect(store.cpu?.total == 0.5)
        #expect(store.cpu?.thermalState == .serious)
    }

    @MainActor @Test(arguments: [true, false])
    func thermalWarningsPreserveDetachedAndMountedPopoverHeight(hasTemperature: Bool) throws {
        let name = "CPUPresentationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        for section in MenuBarItem.cpu.popoverSections { settings.setVisible(section, false) }
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        var baseline: CGFloat?
        let states: [(String, ProcessInfo.ThermalState?)] = [
            ("unknown", nil), ("normal", .nominal), ("elevated", .fair), ("serious", .serious), ("critical", .critical)
        ]
        for (label, state) in states {
            var snapshot = MetricsSnapshot()
            snapshot.cpu = CPULoad(total: 0.3, user: 0.2, system: 0.1, perCore: [], loadAverage: [], thermalState: state)
            snapshot.sensors = SensorReadings(temperatures: hasTemperature ? [
                TemperatureSummary(group: .cpu, average: 55, maximum: 60, sensorCount: 1)
            ] : [], fans: [])
            model.store.apply(snapshot)
            let host = NSHostingView(rootView: VStack { CPUPopover() }
                .environment(model).environment(\.isSnapshot, true).frame(width: DS.Size.popoverWidth))
            let detached = host.fittingSize
            #expect(detached.height > 0)
            if let baseline { #expect(abs(detached.height - baseline) < 1) }
            else { baseline = detached.height }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: detached), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            #expect(abs(host.fittingSize.height - detached.height) < 1)
            // 可选导出真实 AppKit 渲染，走查正常和异常状态，不改变系统热状态。
            if let directory = ProcessInfo.processInfo.environment["XSTATS_CPU_PREVIEW_DIR"] {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: destination.appendingPathComponent("cpu-\(hasTemperature ? "temperature" : "no-sensor")-\(label).png"))
            }
            window.close()
        }
    }
}
