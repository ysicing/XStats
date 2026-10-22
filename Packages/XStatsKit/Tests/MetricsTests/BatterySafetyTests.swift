// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BatterySafetyTests {
  @Test func pausedHubKeepsOnlyLowFrequencyBatteryProtection() async throws {
    let battery = BatteryStatus(
      level: 0.1, isCharging: false, isPluggedIn: false, isFullyCharged: false)
    let hub = MetricsHub(readBattery: { battery })
    var snapshots: [MetricsSnapshot] = []
    await hub.setPaused(true)
    var demand = MetricsDemand()
    demand.cpu = true
    demand.memory = true
    demand.fans = true
    demand.power = true
    demand.batterySafety = true
    await hub.update(demand)
    await hub.start(primeAllMetrics: false) { snapshots.append($0) }
    let deadline = ContinuousClock.now + .seconds(2)
    while snapshots.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let received = snapshots
    let active = await hub.samplingDemand
    demand.batterySafety = false
    await hub.update(demand)
    let stopped = await hub.samplingDemand
    await hub.stop()
    #expect(received.count == 1)
    #expect(received.first?.battery == battery)
    #expect(received.allSatisfy { $0.isSafetySample })
    #expect(
      received.allSatisfy {
        $0.cpu == nil && $0.memory == nil && $0.sensors == nil && $0.power == nil
      })
    #expect(active.battery)
    #expect(active.interval == .seconds(30))
    #expect(!stopped.hasSamples)
  }
}
