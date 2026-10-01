// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
import Metrics
@testable import XStatsUI

@MainActor
struct MetricsStoreTests {
    @Test func diskRankingPreservesGroupingAndDecay() {
        let store = MetricsStore()
        var expected = ActivityRanking()
        let processes = (0..<1_000).map { index in
            var process = ProcessUsage(pid: Int32(index + 1), name: "worker-\(index)", executablePath: nil,
                                       appBundlePath: index % 3 == 0 ? nil : "/Applications/Fixture\(index % 17).app",
                                       cpu: Double(index % 10) / 100, memory: UInt64(index * 1_024))
            process.diskRead = index % 5 == 0 ? nil : Double(index * 17)
            process.diskWrite = index % 7 == 0 ? nil : Double(index * 11)
            return process
        }
        // 包括单独写计数、同应用混合权限、进程退出，以及空采样后的平滑衰减。
        for batch in [processes, Array(processes.prefix(200)), [], [], []] {
            let activity = Dictionary(uniqueKeysWithValues: ProcessRowModel.grouped(batch).map {
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
