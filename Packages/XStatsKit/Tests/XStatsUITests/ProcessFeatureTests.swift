// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Localization
import Testing
@testable import XStatsUI

@MainActor
struct ProcessFeatureTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ProcessFeatureTests.\(UUID())")!
    }

    @Test func defaultsOffAndRejectsSavedOrDirectProcessRoutes() {
        let defaults = defaults()
        defaults.set("processes", forKey: "panelTab")
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.processesEnabled)
        #expect(settings.panelTab == .settingsFeatures)
        settings.panelTab = .processes
        #expect(settings.panelTab == .settingsFeatures)
        #expect(defaults.string(forKey: "panelTab") == "settingsFeatures")
        settings.processesEnabled = true
        settings.panelTab = .processes
        let restored = AppSettings(defaults: defaults)
        #expect(restored.processesEnabled && restored.panelTab == .processes)
        settings.processesEnabled = false
        #expect(settings.panelTab == .settingsFeatures)
        #expect(!AppSettings(defaults: defaults).processesEnabled)
    }

    @Test func disablingProcessPageStopsSystemSamplingWithoutDisablingCPUDetails() {
        let settings = AppSettings(defaults: defaults())
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [])
        model.isMainWindowVisible = true
        settings.processesEnabled = true
        settings.panelTab = .processes
        #expect(model.demand.processes && model.demand.systemProcesses)
        settings.processesEnabled = false
        #expect(!model.demand.processes && !model.demand.systemProcesses)
        model.openPopover = .cpu
        #expect(model.demand.processes && !model.demand.systemProcesses)
        model.openPopover = nil
        settings.processesEnabled = true
        settings.panelTab = .processes
        model.isMainWindowVisible = false
        #expect(!model.demand.processes && !model.demand.systemProcesses)
    }

    @Test func shortcutKeepsItsBindingAndRoutesToTheEnabledDestination() {
        let settings = AppSettings(defaults: defaults())
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [])
        var systemLaunches = 0
        var pages: [PanelTab?] = []
        model.openActivityMonitor = { systemLaunches += 1 }
        model.openMainWindow = { pages.append($0) }
        let key = HotKey(keyCode: 35, modifiers: [.command, .option], key: "p")
        settings.hotKeys[.showProcesses] = key
        let initialPage = settings.panelTab
        model.openProcessMonitor()
        #expect(systemLaunches == 1 && pages.isEmpty)
        #expect(!settings.processesEnabled && settings.panelTab == initialPage)
        #expect(HotKeyAction.showProcesses.title(processesEnabled: false) == tr("打开系统活动监视器"))
        settings.processesEnabled = true
        model.openProcessMonitor()
        #expect(systemLaunches == 1 && pages == [.processes])
        #expect(HotKeyAction.showProcesses.title(processesEnabled: true) == tr("打开进程页"))
        settings.processesEnabled = false
        model.openProcessMonitor()
        #expect(systemLaunches == 2 && pages == [.processes])
        #expect(settings.hotKeys[.showProcesses] == key)
    }

    @Test func disabledFeatureDoesNotStartAnExplanationOrOpenItsPage() {
        let settings = AppSettings(defaults: defaults())
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [])
        var opened = false
        model.openMainWindow = { _ in opened = true }
        model.explainProcess(.init(pid: 42, name: "fixture", displayName: "fixture", executablePath: nil,
                                   appBundlePath: nil, cpu: nil, memory: nil, networkRate: nil))
        #expect(!opened && settings.panelTab != .processes)
        #expect(model.explainer.subject == nil && model.explainer.phase == .idle)
    }

    @Test func backupRoundTripsPreferenceAndOldDocumentsPreserveIt() throws {
        let source = AppSettings(defaults: defaults())
        source.processesEnabled = true
        let data = try JSONEncoder().encode(source.exportDocument())
        let decoded = try JSONDecoder().decode(SettingsDocument.self, from: data)
        let target = AppSettings(defaults: defaults())
        target.apply(decoded)
        #expect(target.processesEnabled)
        target.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
        #expect(target.processesEnabled)
        var disabled = SettingsDocument()
        disabled.processesEnabled = false
        target.panelTab = .processes
        target.apply(disabled)
        #expect(!target.processesEnabled && target.panelTab == .settingsFeatures)
    }
}
