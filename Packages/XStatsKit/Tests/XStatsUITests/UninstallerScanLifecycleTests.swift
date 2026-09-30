// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner
@testable import XStatsUI

@MainActor
struct UninstallerScanLifecycleTests {
    private func app() -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/Scan-\(UUID()).app"), name: "ScanFixture",
                     bundleIdentifier: "test.scan.fixture", version: nil, teamIdentifier: nil)
    }

    @Test func obsoleteScanOfSameApplicationCannotOverwriteNewChoices() async throws {
        let target = app()
        let gate = ScanGate()
        let body = AppLeftover(url: target.url, kind: .application, size: 100)
        let cache = AppLeftover(url: URL(fileURLWithPath: "/tmp/scan-cache"), kind: .caches, size: 100)
        let controller = UninstallerController(currentBundleIdentifier: nil, findLeftovers: { _ in
            if gate.increment() == 1 {
                gate.markStarted()
                _ = gate.release.wait(timeout: .now() + 30)
                gate.markFinished()
            }
            return [body, cache]
        })
        defer { gate.release.signal(); controller.cancelScanning() }
        controller.select(target)
        let started = try await gate.waitUntilStarted()
        try #require(started)
        controller.select(target)
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.isScanning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!controller.isScanning)
        controller.toggle(cache)
        #expect(!controller.chosen.contains(cache.id))
        gate.release.signal()
        while !gate.finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.finished)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.selected == target)
        #expect(controller.chosen == [body.id])
    }

    @Test func sizeCalculationIsSingleAndStopsWhenPageLeaves() async throws {
        let target = app()
        let listCalls = ScanGate()
        let measureCalls = ScanGate()
        let controller = UninstallerController(currentBundleIdentifier: nil,
            listApplications: { _ = listCalls.increment(); return [target] },
            measureSize: { _ in
                if measureCalls.increment() == 1 {
                    measureCalls.markStarted()
                    while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
                    measureCalls.markFinished()
                    throw CancellationError()
                }
                return 321
            })
        defer { controller.cancelScanning() }
        controller.loadApps()
        let started = try await measureCalls.waitUntilStarted()
        try #require(started)
        #expect(controller.isLoading)
        controller.loadApps()
        #expect(listCalls.calls == 1)
        controller.cancelScanning()
        #expect(!controller.isLoading && !controller.isScanning)
        let deadline = ContinuousClock.now + .seconds(30)
        while !measureCalls.finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(measureCalls.finished)
        #expect(controller.sizes[target.id] == nil)
        controller.resumeScanning()
        while controller.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isLoading)
        #expect(controller.sizes[target.id] == 321)
        #expect(listCalls.calls == 2 && measureCalls.calls == 2)
    }

    @Test func clearingSelectionCancelsWorkAndResetsScanningState() async throws {
        let gate = ScanGate()
        let controller = UninstallerController(currentBundleIdentifier: nil, findLeftovers: { _ in
            gate.markStarted()
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            gate.markFinished()
            throw CancellationError()
        })
        defer { controller.cancelScanning() }
        controller.select(app())
        let started = try await gate.waitUntilStarted()
        try #require(started)
        controller.select(nil)
        #expect(controller.selected == nil && !controller.isScanning)
        let deadline = ContinuousClock.now + .seconds(30)
        while !gate.finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.finished && controller.leftovers.isEmpty)
    }
}

/// 同步扫描边界的测试闸门；可变计数与完成状态均由锁保护。
private final class ScanGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var done = false
    private var started = false
    var calls: Int { lock.withLock { count } }
    var finished: Bool { lock.withLock { done } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
    func markFinished() { lock.withLock { done = true } }
    func markStarted() { lock.withLock { started = true } }
    func waitUntilStarted() async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !lock.withLock({ started }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { started }
    }
}
