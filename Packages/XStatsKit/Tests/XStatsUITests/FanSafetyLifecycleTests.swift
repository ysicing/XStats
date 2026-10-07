// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Metrics
import SMC
import Testing
@testable import XStatsUI

@MainActor private final class FanControlFixture: FanControlClient {
    var resetRequests = 0
    var holdReset = false
    var resetContinuation: CheckedContinuation<String?, Never>?
    func setFanTarget(fan: Int, rpm: Double) async -> String? { nil }
    func resetAllFans() async -> String? {
        resetRequests += 1
        if holdReset { return await withCheckedContinuation { resetContinuation = $0 } }
        return nil
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FanSafetyLifecycleTests {
    private func store() -> MetricsStore {
        let store = MetricsStore(readBattery: false)
        var snapshot = MetricsSnapshot()
        snapshot.sensors = SensorReadings(temperatures: [], fans: [
            FanState(id: 0, current: 2_000, minimum: 1_000, maximum: 5_000, target: 2_000, isManual: false)
        ], fanCount: 1)
        store.apply(snapshot)
        return store
    }

    @Test func failedOverheatResetRetainsManualStateAndErrorWhenFeatureIsDisabledDuringReset() async throws {
        let suite = "FanSafetyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let helper = FanControlFixture()
        let fans = FanController(helper: helper, store: store(), settings: settings)
        await fans.select(.custom)
        helper.holdReset = true
        fans.evaluateSafety(temperature: 110)
        while helper.resetContinuation == nil { try Task.checkCancellation(); await Task.yield() }
        settings.setModuleEnabled(.thermal, false)
        helper.resetContinuation?.resume(returning: "fixture-reset-failure")
        helper.resetContinuation = nil
        while fans.isApplying { try Task.checkCancellation(); await Task.yield() }
        #expect(fans.mode == .custom, "复位失败不能把乐观状态当作已经交还系统")
        #expect(fans.noticeIsError)
        #expect(helper.resetRequests == 1)
    }

    @Test func automaticResetDoesNotRequireTheClearedMonitoringCache() async throws {
        let suite = "FanSafetyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let helper = FanControlFixture()
        let store = store()
        let fans = FanController(helper: helper, store: store, settings: settings)
        await fans.select(.custom)
        store.clearDisabledModules([])
        await fans.select(.automatic)
        #expect(helper.resetRequests == 1)
        #expect(fans.mode == .automatic && !fans.noticeIsError)
    }
}
