// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Dispatch
import Foundation
import Testing
@testable import AIUsage

/// 两个 Provider 都把自己钉在 `ScanExecutor.shared` 上。冷启动扫描是几十秒的同步 IO，
/// 留在协作线程池里会把同池的 actor 一起卡住：把池限制成一条线程
/// （`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`）实测，去掉这个执行器后，
/// 并行的每秒采样在整段扫描期间一次都没能推进。
private actor PinnedToScanExecutor {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        ScanExecutor.shared.asUnownedSerialExecutor()
    }

    func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }
}

@Suite struct ScanExecutorTests {
    @Test func pinnedActorsRunOffTheCooperativePool() async {
        let label = await PinnedToScanExecutor().currentQueueLabel()
        #expect(label == "com.xstats.ai-usage-scan")
    }

    /// 串行执行器必须真的串行，否则两个 Provider 会同时抢磁盘和同一个缓存库。
    @Test func workIsSerializedAcrossPinnedActors() async {
        let first = PinnedToScanExecutor()
        let second = PinnedToScanExecutor()
        async let a = first.currentQueueLabel()
        async let b = second.currentQueueLabel()
        let labels = await [a, b]
        #expect(labels == ["com.xstats.ai-usage-scan", "com.xstats.ai-usage-scan"])
    }
}
