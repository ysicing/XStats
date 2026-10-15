// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics

struct ThermalSummaryTests {
    @MainActor @Test func temperatureDemandReadsSystemThermalStateWithoutSamplingCPUAndStopsWhenClosed() async throws {
        let hub = MetricsHub()
        var snapshots: [MetricsSnapshot] = []
        var demand = MetricsDemand()
        demand.temperatures = [.cpu]
        demand.interval = .seconds(60)
        await hub.update(demand)
        await hub.start(primeAllMetrics: false) { snapshots.append($0) }
        let deadline = ContinuousClock.now + .seconds(3)
        while snapshots.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.thermalState != nil)
        #expect(snapshot.cpu == nil && snapshot.processes == nil && snapshot.power == nil)
        await hub.update(MetricsDemand())
        let count = snapshots.count
        try await Task.sleep(for: .milliseconds(550))
        #expect(snapshots.count == count)
        await hub.stop()
    }
}
