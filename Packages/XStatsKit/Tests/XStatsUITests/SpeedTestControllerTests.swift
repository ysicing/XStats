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

    @Test func stageUpdateQueuedBeforeStopDoesNotRestartBroadband() async {
        let suite = "SpeedTestControllerTests.stop.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = SpeedProbeGate()
        let controller = SpeedTestController(settings: AppSettings(defaults: defaults)) { _, _, stage, progress in
            // 用户点停止之后，测速代码才送出阶段与进度回调，模拟排在停止之后的过期回调
            await gate.wait()
            stage(.download)
            progress(50_000_000, 0)
            return BroadbandResult()
        }
        controller.runBroadband()
        await gate.waitUntilStarted()
        controller.runBroadband() // 第二次点击即停止
        #expect(!controller.isTestingBroadband)
        await gate.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.broadbandStage == nil, "stale stage callback re-entered the testing state")
        #expect(controller.liveBitsPerSecond == 0)
    }

    @Test func completedBroadbandIgnoresLateStageUpdates() async {
        let suite = "SpeedTestControllerTests.done.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SpeedTestController(settings: AppSettings(defaults: defaults)) { _, _, stage, _ in
            // 结果写入之后才到达的阶段回调
            Task.detached {
                try? await Task.sleep(for: .milliseconds(50))
                stage(.upload)
            }
            return BroadbandResult()
        }
        controller.runBroadband()
        // resolvePath 会读取真实代理环境，按时间等待结果写入
        for _ in 0..<200 where controller.broadbandDate == nil { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(controller.broadbandDate != nil)
        #expect(!controller.isTestingBroadband, "late stage callback revived a finished test")
    }
}
