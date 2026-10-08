// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner
@testable import XStatsUI

/// 记录扫描闭包在后台线程上的进展，供主线程测试轮询
private final class ScanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var startedValue = false
    private var cancelledValue = false

    var started: Bool { lock.withLock { startedValue } }
    var cancelled: Bool { lock.withLock { cancelledValue } }
    func markStarted() { lock.withLock { startedValue = true } }
    func markCancelled() { lock.withLock { cancelledValue = true } }
}

private struct ScanNeverCancelled: Error {}

@MainActor
struct DiskToolsScanTests {
    @Test func cancellingScanStopsTraversalAndReturnsToIdle() async throws {
        let probe = ScanProbe()
        let controller = DiskToolsController(
            helper: HelperClient(teamIdentifier: nil, service: SystemHelperRegistration()),
            defaults: UserDefaults(suiteName: "DiskToolsScanTests-\(UUID())")!,
            scanSpace: { _ in
                probe.markStarted()
                // 模拟遍历中的取消检查点；取消未转发时 30 秒后以其他错误结束
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    if Task.isCancelled {
                        probe.markCancelled()
                        throw CancellationError()
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                throw ScanNeverCancelled()
            })

        controller.startScan()
        let startDeadline = ContinuousClock.now + .seconds(10)
        while !probe.started, ContinuousClock.now < startDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(probe.started)
        guard case .scanning = controller.scanPhase else {
            Issue.record("expected scanning, got \(controller.scanPhase)")
            return
        }

        controller.cancelScan()
        let idleDeadline = ContinuousClock.now + .seconds(5)
        while controller.scanPhase != .idle, ContinuousClock.now < idleDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.cancelled, "scan closure never observed cancellation")
        #expect(controller.scanPhase == .idle, "phase after cancel: \(controller.scanPhase)")
    }
}
