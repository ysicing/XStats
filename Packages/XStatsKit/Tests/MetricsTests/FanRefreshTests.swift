// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics

struct FanRefreshTests {
    @Test @MainActor func directFanReadsRespectDemandPauseAndStopWithoutPublishingSnapshots() async throws {
        let hub = MetricsHub()
        #expect(await hub.sampleFans() == nil)
        var snapshots = 0
        await hub.start(primeAllMetrics: false) { _ in snapshots += 1 }
        #expect(await hub.sampleFans() == nil)
        var demand = MetricsDemand()
        demand.fans = true
        demand.interval = .seconds(60)
        await hub.update(demand)
        // 暂停并恢复后，直接读取不启动额外的全量采样，也不绕过停用状态。
        await hub.setPaused(true)
        #expect(await hub.sampleFans() == nil)
        await hub.setPaused(false)
        let deadline = ContinuousClock.now + .seconds(3)
        while snapshots == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(snapshots > 0)
        let before = snapshots
        _ = await hub.sampleFans()
        _ = await hub.sampleFans()
        try await Task.sleep(for: .milliseconds(50))
        #expect(snapshots == before)
        await hub.stop()
        #expect(await hub.sampleFans() == nil)
        #expect(snapshots == before)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_FAN_RESOURCE_REPORT"] != nil))
    @MainActor func realFanReadsReuseTheHubAndStopOnPauseAndClose() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["XSTATS_FAN_RESOURCE_REPORT"])
        let hub = MetricsHub()
        var snapshots = 0
        await hub.start(primeAllMetrics: false) { snapshot in
            snapshots += 1
            #expect(snapshot.cpu == nil && snapshot.power == nil && snapshot.gpu == nil && snapshot.processes == nil)
        }
        var demand = MetricsDemand()
        demand.fans = true
        demand.interval = .seconds(60)
        await hub.update(demand)
        let start = ContinuousClock.now
        let reading = try #require(await hub.sampleFans())
        #expect(!reading.isEmpty)
        let elapsed = start.duration(to: .now).components
        await hub.setPaused(true)
        #expect(await hub.sampleFans() == nil)
        await hub.setPaused(false)
        #expect(await hub.sampleFans() != nil)
        demand.fans = false
        demand.generation += 1
        await hub.update(demand)
        snapshots = 0
        #expect(await hub.sampleFans() == nil)
        try await Task.sleep(for: .milliseconds(700))
        #expect(snapshots == 0)
        await hub.stop()
        #expect(await hub.sampleFans() == nil)
        let report: [String: Any] = ["fanCount": reading.count,
            "readSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            "closedSnapshots": snapshots, "pausedReadRejected": true, "stoppedReadRejected": true]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
