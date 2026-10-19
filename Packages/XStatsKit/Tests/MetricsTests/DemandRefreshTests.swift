// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics

@MainActor
struct DemandRefreshTests {
  /// 关闭弹窗、切页只会减少需求或拉长间隔；立即重采样会让 CPU 等增量指标基于过短的区间计算，
  /// 并给实时曲线多塞一个时间间隔不均匀的点。
  @Test func reducingDemandWaitsForTheNextScheduledSample() async throws {
    let hub = MetricsHub()
    var snapshots = 0
    await hub.start(primeAllMetrics: false) { _ in snapshots += 1 }
    defer { Task { await hub.stop() } }
    var demand = MetricsDemand()
    demand.cpu = true
    demand.memory = true
    demand.interval = .seconds(60)
    await hub.update(demand)
    try await waitUntil { snapshots == 1 }

    demand.cpu = false
    demand.interval = .seconds(120)
    await hub.update(demand)
    try await Task.sleep(for: .milliseconds(300))
    #expect(snapshots == 1)
  }

  /// 进程页需要尽快显示系统进程，即使其他需求不变、间隔很长也要立即采样。
  @Test func openingTheProcessPageSamplesImmediately() async throws {
    let hub = MetricsHub()
    var processSnapshots = 0
    var snapshots = 0
    await hub.start(primeAllMetrics: false) { snapshot in
      snapshots += 1
      if snapshot.processes != nil { processSnapshots += 1 }
    }
    defer { Task { await hub.stop() } }
    var demand = MetricsDemand()
    demand.memory = true
    demand.interval = .seconds(60)
    await hub.update(demand)
    try await waitUntil { snapshots == 1 }

    demand.systemProcesses = true
    await hub.update(demand)
    try await waitUntil { processSnapshots == 1 }
  }

  @Test func disablingAllDemandStopsSamplingAndRejectsAnOlderEnableRequest() async throws {
    let hub = MetricsHub()
    var snapshots = 0
    await hub.start(primeAllMetrics: false) { _ in snapshots += 1 }
    defer { Task { await hub.stop() } }
    var demand = MetricsDemand()
    demand.memory = true
    demand.generation = 1
    demand.interval = .seconds(60)
    await hub.update(demand)
    try await waitUntil { snapshots == 1 }
    // 缩短间隔仍须即时刷新。
    demand.interval = .milliseconds(100)
    await hub.update(demand)
    try await waitUntil { snapshots >= 2 }
    let beforeStop = snapshots
    var disabled = MetricsDemand()
    disabled.generation = 2
    disabled.interval = demand.interval
    await hub.update(disabled)
    await hub.update(demand)
    try await Task.sleep(for: .milliseconds(350))
    #expect(snapshots == beforeStop)
    demand.generation = 3
    await hub.update(demand)
    try await waitUntil { snapshots > beforeStop }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
}
