// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Metrics
import Testing
@testable import XStatsUI

private actor SpeedProbeGate {
    private var started: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    private var didStart = false

    func wait() async {
        didStart = true
        started?.resume()
        started = nil
        await withCheckedContinuation { blocked = $0 }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        blocked?.resume()
        blocked = nil
    }
}

@MainActor
@Suite struct SpeedTestControllerTests {
    @Test func cancelledRouteDoesNotPublishOldProbeResult() async {
        let suite = "SpeedTestControllerTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let controller = SpeedTestController(settings: settings)
        let gate = SpeedProbeGate()
        var published: [Int] = []
        let task = Task {
            await controller.measure([1], concurrency: 1) { _ in
                await gate.wait()
                return LatencyResult(best: 12, attempts: 1)
            } done: { node, _ in
                published.append(node)
            }
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        await task.value
        #expect(published.isEmpty)
    }
}
