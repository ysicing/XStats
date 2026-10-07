// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Metrics
import Testing
@testable import XStatsUI

/// 每个用例使用独立偏好域，实例释放时删除，避免在本机留下测试 plist。
@MainActor
final class MonitoringFeatureTests {
    private var suites: [String] = []

    deinit {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    @Test func changingFeatureCategoryKeepsPreferencesAndSamplingDemandUnchanged() {
        let settings = settings()
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        settings.setModuleEnabled(.gpu, false)
        settings.panelTab = .settingsFeatures
        model.isMainWindowVisible = true
        let preferences = settings.exportDocument()
        let demand = model.demand
        for _ in 0..<10 {
            model.featureSettingsTab = .optional
            model.featureSettingsTab = .basic
        }
        #expect(settings.exportDocument() == preferences)
        #expect(model.demand == demand)
        #expect(!settings.isModuleEnabled(.gpu))
    }

    private func settings() -> AppSettings {
        let suite = "MonitoringFeatureTests.\(UUID())"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        return AppSettings(defaults: defaults)
    }

    @Test func menuEntryEnablesItsModuleButRemovingItDoesNotDisableTheModule() {
        let settings = settings()
        settings.setModuleEnabled(.gpu, false)
        settings.setEnabled(.gpu, true)
        #expect(settings.isModuleEnabled(.gpu))
        #expect(settings.orderedMenuBarItems.contains(.gpu))
        settings.setEnabled(.gpu, false)
        #expect(settings.isModuleEnabled(.gpu))
        settings.setModuleEnabled(.thermal, false)
        settings.menuBarItems.insert(.fan)
        #expect(settings.isModuleEnabled(.thermal))
        settings.setModuleEnabled(.thermal, false)
        #expect(!settings.menuBarItems.contains(.fan) && !settings.menuBarItems.contains(.temperature))
        settings.enabledMonitoringModules = []
        settings.menuBarItems = [.cpu, .gpu, .memory]
        #expect(settings.orderedMenuBarItems == [.cpu, .memory, .gpu])
    }

    @Test func displayMenuShowsInfoWithoutEnablingParameterControls() {
        let settings = settings()
        settings.setModuleEnabled(.display, false)
        settings.setEnabled(.display, true)
        #expect(settings.orderedMenuBarItems.contains(.display))
        #expect(!settings.isModuleEnabled(.display))
        settings.setModuleEnabled(.display, true)
        settings.setModuleEnabled(.display, false)
        #expect(settings.orderedMenuBarItems.contains(.display))
        #expect(settings.exportDocument().enabledMonitoringModules?.contains("display") == false)
    }

    @Test func menuEntriesAlsoEnableExistingOptionalFeatures() {
        let settings = settings()
        settings.setEnabled(.aiUsage, true)
        settings.setEnabled(.audio, true)
        #expect(settings.aiUsageEnabled && settings.audioEnabled)
    }

    @Test func noConsumerMeansNoSamplingEvenWhenModulesAreEnabled() {
        let settings = settings()
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        settings.menuBarItems = []
        settings.historyEnabled = false
        settings.enabledAlerts = []
        #expect(!model.demand.hasSamples)
        settings.historyEnabled = true
        #expect(model.demand.cpu && model.demand.memory && model.demand.network)
        settings.enabledMonitoringModules = []
        #expect(!model.demand.hasSamples)
    }

    @Test func disabledModulesCannotBeReactivatedByVisiblePagesOrAlerts() {
        let settings = settings()
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        settings.enabledMonitoringModules = []
        settings.enabledAlerts = Set(AlertKind.allCases)
        model.isMainWindowVisible = true
        for tab in [PanelTab.overview, .cpu, .gpu, .memory, .network, .disk, .thermal, .battery, .system] {
            settings.panelTab = tab
            #expect(!model.demand.hasSamples)
            #expect(model.bluetoothDemand == .off)
            #expect(!model.displayControlsVisible)
        }
        #expect(settings.activeAlerts.isEmpty)
        #expect(settings.enabledAlerts == Set(AlertKind.allCases), "关闭功能保留告警偏好")
    }

    @Test func processSummaryRequestsEnabledCPUWithoutHistoryOrMenu() {
        let settings = settings()
        settings.historyEnabled = false
        settings.menuBarItems = []
        settings.processesEnabled = true
        settings.panelTab = .processes
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        model.isMainWindowVisible = true
        #expect(model.demand.cpu && model.demand.systemProcesses)
        settings.setModuleEnabled(.cpu, false)
        #expect(!model.demand.cpu && model.demand.systemProcesses)
    }

    @Test func lateSnapshotsCannotRepublishDisabledMetrics() {
        let settings = settings()
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        var snapshot = MetricsSnapshot()
        snapshot.cpu = CPULoad(total: 0.95, user: 0.6, system: 0.35, perCore: [0.95], loadAverage: [])
        model.handle(snapshot)
        #expect(model.store.cpu != nil)
        settings.setModuleEnabled(.cpu, false)
        model.handle(snapshot)
        #expect(model.store.cpu == nil)
        #expect(model.store.cpuTotal.elements.isEmpty)
    }

    @Test func disablingModulesClearsTheirLiveHistories() {
        let store = MetricsStore(readBattery: false)
        var snapshot = MetricsSnapshot()
        snapshot.network = NetworkRate(downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500, totalDownloaded: 0, totalUploaded: 0)
        snapshot.gpu = GPUUsage(name: "Fixture GPU", utilization: 0.4)
        snapshot.power = PowerReading(system: 30)
        store.apply(snapshot)
        #expect(!store.downloadHistory.elements.isEmpty && !store.gpuHistory.elements.isEmpty && !store.powerHistory.elements.isEmpty)
        store.clearDisabledModules([.cpu, .memory, .disk, .battery])
        #expect(store.network == nil && store.downloadHistory.elements.isEmpty && store.uploadHistory.elements.isEmpty,
                "网络关闭后不能保留旧速率曲线")
        #expect(store.gpu == nil && store.gpuHistory.elements.isEmpty, "GPU 关闭后不能保留旧占用曲线")
        #expect(store.power == nil && store.powerHistory.elements.isEmpty, "温度与风扇关闭后不能保留旧功耗曲线")
    }

    @Test func closingAndReenablingRejectsSnapshotsAlreadyQueuedBeforeDemandDelivery() {
        let settings = settings()
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        var snapshot = MetricsSnapshot()
        snapshot.samplingGeneration = settings.monitoringGeneration
        snapshot.cpu = CPULoad(total: 0.95, user: 0.6, system: 0.35, perCore: [0.95], loadAverage: [])
        settings.setModuleEnabled(.cpu, false)
        settings.setModuleEnabled(.cpu, true)
        model.handle(snapshot)
        #expect(model.store.cpu == nil)
        snapshot.samplingGeneration = settings.monitoringGeneration
        model.handle(snapshot)
        #expect(model.store.cpu?.total == 0.95)
    }

    @Test func cpuFrequencySurvivesWithoutThermalPowerAndDisabledThermalValuesStayHidden() {
        let settings = settings()
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        settings.setModuleEnabled(.thermal, false)
        var snapshot = MetricsSnapshot()
        snapshot.power = PowerReading(system: 30, gpu: 5, clusterFrequency: [0: 3_000])
        model.handle(snapshot)
        #expect(model.store.power?.clusterFrequency == [0: 3_000])
        #expect(model.store.power?.system == nil && model.store.power?.gpu == nil)
        #expect(model.store.powerHistory.elements.isEmpty)
    }

    @Test func disabledThermalShortcutOpensItsEnablePageWithoutStartingControl() {
        let settings = settings()
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        settings.setModuleEnabled(.thermal, false)
        var pages: [PanelTab?] = []
        model.openMainWindow = { pages.append($0) }
        model.requestFanMode(.cooling)
        #expect(pages == [.thermal])
        #expect(model.fans.mode == .automatic && !model.fans.isApplying)
        #expect(!settings.isModuleEnabled(.thermal))
    }

    @Test func backupPreservesDisabledModulesAndConflictingMenuChoicesDoNotOverrideThem() throws {
        let source = settings()
        source.setModuleEnabled(.cpu, false)
        source.setModuleEnabled(.thermal, false)
        var document = source.exportDocument()
        document.menuBarItems = ["cpu", "fan", "memory"]
        let decoded = try JSONDecoder().decode(SettingsDocument.self, from: JSONEncoder().encode(document))
        let target = settings()
        target.apply(decoded)
        #expect(!target.isModuleEnabled(.cpu) && !target.isModuleEnabled(.thermal))
        #expect(!target.orderedMenuBarItems.contains(.cpu) && !target.orderedMenuBarItems.contains(.fan))
        target.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
        #expect(!target.isModuleEnabled(.cpu))
    }
}
