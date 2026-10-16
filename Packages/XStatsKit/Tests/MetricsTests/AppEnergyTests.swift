// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Metrics

struct AppEnergyTests {
  @MainActor
  @Test func reopeningMeasuresTheNextLoopAfterBaselineAndStopsWhenClosed() async throws {
    let hub = MetricsHub()
    // 记录每个快照是否带能耗读数，按采样轮次而非墙钟判断首个区间的时机，负载下也稳定。
    var snapshots: [AppEnergyReading?] = []
    await hub.start(primeAllMetrics: false) { snapshot in snapshots.append(snapshot.appEnergy) }
    var demand = MetricsDemand()
    demand.interval = .seconds(1)
    for _ in 0..<2 {
      snapshots.removeAll()
      demand.generation += 1
      demand.appEnergy = true
      await hub.update(demand)
      let deadline = ContinuousClock.now + .seconds(30)
      while !snapshots.contains(where: { $0?.interval != nil }), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      let readings = snapshots.compactMap { $0 }
      #expect(readings.first?.interval == nil)
      // 基线之后的下一轮就给出区间，而不是等完整的五秒刷新周期。
      let baseline = try #require(snapshots.firstIndex { $0 != nil })
      #expect(snapshots.indices.contains(baseline + 1) && snapshots[baseline + 1]?.interval != nil)
      demand.generation += 1
      demand.appEnergy = false
      await hub.update(demand)
      snapshots.removeAll()
      try await Task.sleep(for: .milliseconds(400))
      #expect(snapshots.isEmpty)
    }
    await hub.stop()
  }

  private func counter(
    _ pid: Int32, start: UInt64 = 10, energy: UInt64,
    bundle: String? = nil
  ) -> AppEnergySampler.Counter {
    .init(
      identity: .init(pid: pid, startTime: start), nanojoules: energy,
      name: "Process \(pid)", bundlePath: bundle)
  }

  @Test func baselineAndHelpersUseMeasuredIntervalAndNanojoules() throws {
    var sampler = AppEnergySampler()
    let initial = sampler.reading(
      counters: [
        counter(1, energy: 1_000_000_000, bundle: "/Demo.app"),
        counter(2, energy: 2_000_000_000, bundle: "/Demo.app"),
      ], now: 100)
    #expect(initial.interval == nil && initial.apps.isEmpty && initial.isAvailable)
    let reading = sampler.reading(
      counters: [
        counter(1, energy: 2_000_000_000, bundle: "/Demo.app"),
        counter(2, energy: 4_000_000_000, bundle: "/Demo.app"),
      ], now: 110)
    let app = try #require(reading.apps.first)
    #expect(reading.interval == 10 && reading.apps.count == 1)
    #expect(abs(app.watts - 0.3) < 0.000001 && app.id == "/Demo.app")
    #expect(abs(reading.totalWatts - 0.3) < 0.000001)
  }

  @Test func reusedPIDsAndCounterResetsCannotCreatePowerSpikes() {
    var sampler = AppEnergySampler()
    _ = sampler.reading(counters: [counter(1, energy: 100), counter(2, energy: 200)], now: 10)
    let reading = sampler.reading(
      counters: [
        counter(1, start: 20, energy: 90_000_000_000),
        counter(2, energy: 10),
      ], now: 15)
    #expect(reading.apps.isEmpty && reading.totalWatts == 0)
    // 退出后再次出现的进程必须重新建立基线，不能保留旧缓存。
    _ = sampler.reading(counters: [], now: 20)
    #expect(sampler.reading(counters: [counter(2, energy: 1_000_000_000)], now: 25).apps.isEmpty)
  }

  @Test func rankIsBoundedAndTotalIncludesRowsOutsideTopFive() {
    var sampler = AppEnergySampler()
    _ = sampler.reading(counters: (1...20).map { counter(Int32($0), energy: 0) }, now: 10)
    let reading = sampler.reading(
      counters: (1...20).map { counter(Int32($0), energy: UInt64($0) * 1_000_000_000) }, now: 15)
    #expect(reading.apps.count == 5 && reading.apps.first?.name == "Process 20")
    #expect(abs(reading.totalWatts - 42) < 0.000001)
  }

  @Test func unavailableCountersAndClockResetNeverInventEnergy() {
    var sampler = AppEnergySampler()
    let unavailable = sampler.reading(counters: [counter(1, energy: 0)], now: 10)
    #expect(!unavailable.isAvailable && unavailable.apps.isEmpty)
    let reset = sampler.reading(counters: [counter(1, energy: 100)], now: 9)
    #expect(reset.interval == nil && reset.apps.isEmpty && reset.totalWatts == 0)
  }
}
