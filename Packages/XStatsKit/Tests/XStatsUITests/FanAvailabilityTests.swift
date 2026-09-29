// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Metrics
import SMC
import Testing
@testable import XStatsUI

@MainActor
struct FanAvailabilityTests {
    @Test func onlyConfirmedFansAppearAndPreferencesArePreserved() throws {
        let name = "FanAvailabilityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.menuBarItems = [.temperature, .fan]
        settings.panelTab = .thermal
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        model.isMainWindowVisible = true
        #expect(!model.availableMenuBarItems.contains(.fan))
        #expect(!model.visibleMenuBarItems.contains(.fan))
        #expect(model.demand.fans)
        var snapshot = MetricsSnapshot()
        snapshot.sensors = SensorReadings(temperatures: [], fans: [], fanCount: 0)
        model.store.apply(snapshot)
        #expect(!model.store.supportsFans)
        #expect(!model.availableMenuBarItems.contains(.fan))
        #expect(model.visibleMenuBarItems == [.temperature])
        #expect(!model.demand.fans)
        #expect(settings.menuBarItems.contains(.fan))
        // 后续仅采温度或读取失败不会让入口来回闪烁。
        snapshot.sensors = SensorReadings(temperatures: [], fans: [])
        model.store.apply(snapshot)
        #expect(!model.store.supportsFans)
        snapshot.sensors = SensorReadings(temperatures: [], fans: [], fanCount: 2)
        model.store.apply(snapshot)
        #expect(model.store.supportsFans)
        #expect(model.visibleMenuBarItems.contains(.fan))
        #expect(model.demand.fans)
    }

    @Test func unknownFansStayHiddenAndStoppedFansRemainVisible() {
        let store = MetricsStore()
        var snapshot = MetricsSnapshot()
        snapshot.sensors = SensorReadings(temperatures: [], fans: [])
        store.apply(snapshot)
        #expect(!store.supportsFans)
        let stopped = FanState(id: 0, current: 0, minimum: 0, maximum: 6000, target: 0, isManual: false)
        snapshot.sensors = SensorReadings(temperatures: [], fans: [stopped], fanCount: 1)
        store.apply(snapshot)
        #expect(store.supportsFans)
        #expect(store.fastestFan?.current == 0)
        snapshot.sensors = SensorReadings(temperatures: [], fans: [])
        store.apply(snapshot)
        #expect(store.supportsFans)
    }
}
