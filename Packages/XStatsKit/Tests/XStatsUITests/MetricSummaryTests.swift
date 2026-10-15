// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct MetricSummaryTests {
    @Test func cpuScaleDefaultsToMachineAndOldBackupsPreserveTheSelection() throws {
        let suite = "MetricSummaryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.cpuSharePerCore)
        settings.cpuSharePerCore = true
        settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
        #expect(settings.cpuSharePerCore)
        // 两个线程各占满一个核心时，单核口径必须允许超过 100%。
        let twoCores = 200.0.formatted(.number.precision(.fractionLength(1))) + "%"
        #expect(settings.processCPUText(2) == twoCores)
        settings.cpuSharePerCore = false
        let machine = (200.0 / Double(ProcessInfo.processInfo.activeProcessorCount))
            .formatted(.number.precision(.fractionLength(1))) + "%"
        #expect(settings.processCPUText(2) == machine)
    }

    @Test func cpuScaleSurvivesImportPersistenceAndExportWithoutChangingSampling() throws {
        let suite = "MetricSummaryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        let demand = model.demand
        for enabled in [true, false] {
            settings.apply(try JSONDecoder().decode(SettingsDocument.self,
                from: Data("{\"cpuSharePerCore\":\(enabled)}".utf8)))
            let restored = AppSettings(defaults: defaults)
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.exportDocument())) as? [String: Any])
            #expect(object["cpuSharePerCore"] as? Bool == enabled)
            #expect(model.demand == demand)
        }
    }

    @Test func temperatureSummaryUpdatesWithoutCPUReadingsAndClearsWhenMonitoringStops() throws {
        let suite = "MetricSummaryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.enabledMonitoringModules = [.battery]
        settings.historyEnabled = false
        settings.enabledAlerts = []
        settings.menuBarItems = []
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        model.openPopover = .temperature
        let demand = model.demand
        #expect(!demand.cpu && !demand.temperatures.isEmpty)
        var snapshot = MetricsSnapshot()
        snapshot.thermalState = .serious
        model.handle(snapshot)
        #expect(model.store.thermalState == .serious)
        #expect(model.store.cpu == nil && model.store.cpuTimeline.elements.isEmpty)
        settings.setModuleEnabled(.battery, false)
        model.applyMonitoringSettings()
        #expect(model.store.thermalState == nil)
        model.handle(snapshot)
        #expect(model.store.thermalState == nil)
    }
}
