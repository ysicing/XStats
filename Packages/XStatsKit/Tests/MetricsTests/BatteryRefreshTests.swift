// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import IOKit.ps
import Testing
@testable import Metrics

struct BatteryRefreshTests {
    @Test func presenceDistinguishesAbsentBatteryIncompleteReadAndExternalPowerSource() {
        #expect(BatterySampler.readPowerSources(nil).hasInternalBattery == nil)
        #expect(BatterySampler.readPowerSources([]).hasInternalBattery == false)
        #expect(BatterySampler.readPowerSources([nil]).hasInternalBattery == nil)
        #expect(BatterySampler.readPowerSources([[:]]).hasInternalBattery == nil)
        let external: [String: Any] = [kIOPSTypeKey: kIOPSUPSType]
        #expect(BatterySampler.readPowerSources([external]).hasInternalBattery == false)
        #expect(BatterySampler.readPowerSources([external, nil]).hasInternalBattery == nil)
        let internalSource: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 50,
                                           kIOPSMaxCapacityKey: 100]
        let reading = BatterySampler.readPowerSources([nil, external, internalSource])
        #expect(reading.hasInternalBattery == true)
        #expect(reading.battery?.level == 0.5)
    }

    @Test @MainActor func eventRefreshRespectsDemandPauseStopAndOnlyReadsBattery() async throws {
        let hub = MetricsHub()
        var snapshots: [MetricsSnapshot] = []
        #expect(await hub.sampleBattery() == nil)
        await hub.start(primeAllMetrics: false) { snapshots.append($0) }
        #expect(await hub.sampleBattery() == nil)
        #expect(snapshots.isEmpty)
        var demand = MetricsDemand()
        demand.battery = true
        demand.generation = 3
        demand.interval = .seconds(60)
        await hub.update(demand)
        let deadline = ContinuousClock.now + .seconds(3)
        while snapshots.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!snapshots.isEmpty)
        let count = snapshots.count
        let result = try #require(await hub.sampleBattery())
        #expect(snapshots.count == count)
        #expect(result.samplingGeneration == 3)
        #expect(result.cpu == nil && result.power == nil && result.sensors == nil && result.appEnergy == nil)
        await hub.setPaused(true)
        let pausedCount = snapshots.count
        #expect(await hub.sampleBattery() == nil)
        #expect(snapshots.count == pausedCount)
        await hub.stop()
        #expect(await hub.sampleBattery() == nil)
        #expect(snapshots.count == pausedCount)
    }
}
