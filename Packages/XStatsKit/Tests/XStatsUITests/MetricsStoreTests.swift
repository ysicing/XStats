// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct MetricsStoreTests {
  /// onChange 是 @Sendable 闭包，用带锁的计数器记录通知次数。
  private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
  }

  @Test func batteryPresenceChangesOnlyOnFirstReading() {
    let store = MetricsStore(readBattery: false)
    let changes = ChangeCounter()
    func observe() {
      withObservationTracking {
        _ = store.hasBattery
      } onChange: {
        changes.increment()
      }
    }
    func apply(amperage: Double) {
      var snapshot = MetricsSnapshot()
      snapshot.battery = BatteryStatus(
        level: 0.8, isCharging: false, isPluggedIn: true, isFullyCharged: false,
        minutesRemaining: nil, cycleCount: 100, health: 0.9, amperage: amperage)
      store.apply(snapshot)
    }

    #expect(!store.hasBattery)
    observe()
    apply(amperage: -1.0)
    #expect(store.hasBattery && changes.value == 1)

    // 之后电压、电流等读数持续变化，不应再通知只关心"是否有电池"的观察者。
    observe()
    apply(amperage: -1.2)
    apply(amperage: -0.9)
    #expect(changes.value == 1)
  }

  @Test func diskRankingPreservesGroupingAndDecay() {
    let store = MetricsStore()
    var expected = ActivityRanking()
    let processes = (0..<1_000).map { index in
      var process = ProcessUsage(
        pid: Int32(index + 1), name: "worker-\(index)", executablePath: nil,
        appBundlePath: index % 3 == 0 ? nil : "/Applications/Fixture\(index % 17).app",
        cpu: Double(index % 10) / 100, memory: UInt64(index * 1_024))
      process.diskRead = index % 5 == 0 ? nil : Double(index * 17)
      process.diskWrite = index % 7 == 0 ? nil : Double(index * 11)
      return process
    }
    // 包括单独写计数、同应用混合权限、进程退出，以及空采样后的平滑衰减。
    for batch in [processes, Array(processes.prefix(200)), [], [], []] {
      let activity = Dictionary(
        uniqueKeysWithValues: ProcessRowModel.grouped(batch).map {
          ($0.id, $0.disk.map { $0.read + $0.write } ?? 0)
        })
      expected.update(activity)
      var snapshot = MetricsSnapshot()
      snapshot.processes = batch
      store.apply(snapshot)
      #expect(store.diskRanking == expected)
      #expect(store.processes == batch)
    }
  }
}
