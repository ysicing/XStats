// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

private final class ResetCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor TestDisplayBackend: DisplayDDCBackend {
    var reads = 0
    var writes = 0
    var readResult: [DisplayControl: DDCResult] = [.brightness: .value(DDCValue(current: 75, maximum: 100)), .volume: .unsupported]
    var writeResult = DDCResult.value(DDCValue(current: 60, maximum: 100))
    var gateReads = false
    var gates: [CheckedContinuation<[DisplayControl: DDCResult], Never>] = []
    var tickets: [DDCCancellation] = []
    var timingOutTargets: Set<UInt32> = []
    nonisolated let resets = ResetCounter()
    func read(_ target: DisplayTarget, cancellation: DDCCancellation) async -> [DisplayControl: DDCResult] {
        reads += 1
        tickets.append(cancellation)
        // 与 NativeDisplayDDC.execute 一致：超时时取消传入的令牌
        if timingOutTargets.contains(target.id) {
            cancellation.cancel()
            return [.brightness: .timedOut]
        }
        if gateReads { return await withCheckedContinuation { gates.append($0) } }
        return readResult
    }
    func write(_ target: DisplayTarget, control: DisplayControl, percent: Double, cancellation: DDCCancellation) async -> DDCResult {
        writes += 1
        return writeResult
    }
    nonisolated func resetConnections() { resets.increment() }
    func block() { gateReads = true }
    func timeOut(_ id: UInt32) { timingOutTargets.insert(id) }
    func finish(_ value: UInt16) { gates.removeFirst().resume(returning: [.brightness: .value(DDCValue(current: value, maximum: 100))]) }
    func setWriteResult(_ value: DDCResult) { writeResult = value }
    func count() -> Int { reads }
    func writeCount() -> Int { writes }
    func wasCancelled(_ index: Int) -> Bool { tickets[index].isCancelled }
}

@MainActor
struct DisplayControllerTests {
    private var display: DisplayInfo {
        DisplayInfo(target: DisplayTarget(id: 7, identity: "fixture-connection"), name: "Fixture Display",
                    isBuiltIn: false, isMain: true, summary: "1920×1080 · 60Hz")
    }
    private func waitForReads(_ backend: TestDisplayBackend, _ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while await backend.count() < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await backend.count() >= count)
    }
    private func settle(_ controller: DisplayController) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.isRefreshing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isRefreshing)
    }

    @Test func timeoutOnOneDisplayDoesNotSkipTheNextDisplay() async throws {
        let backend = TestDisplayBackend()
        await backend.timeOut(7)
        let second = DisplayInfo(target: DisplayTarget(id: 8, identity: "fixture-second"), name: "Second Display",
                                 isBuiltIn: false, isMain: false, summary: "2560×1440 · 60Hz")
        let controller = DisplayController(backend: backend, catalog: [display, second])
        defer { controller.stop() }
        controller.setVisible(true)
        try await waitForReads(backend, 2)
        try await settle(controller)
        #expect(await backend.wasCancelled(0))
        #expect(!(await backend.wasCancelled(1)))
        #expect(controller.readings[7]?[.brightness] == .timedOut)
        #expect(controller.readings[8]?[.brightness] == .value(DDCValue(current: 75, maximum: 100)))
    }

    @Test func wakeDropsMatchedConnectionsButVisibilityChangesKeepThem() async throws {
        let backend = TestDisplayBackend()
        let controller = DisplayController(backend: backend, catalog: [display])
        defer { controller.stop() }
        controller.setVisible(true)
        controller.setVisible(false)
        controller.setVisible(true)
        #expect(backend.resets.value == 0)
        controller.setPaused(true)
        #expect(backend.resets.value == 0)
        controller.setPaused(false)
        #expect(backend.resets.value == 1)
        await controller.redetect()
        #expect(backend.resets.value == 2)
    }

    @Test func onlyVisibleControlsReadAndOnlyKnownSupportedControlsWrite() async throws {
        let backend = TestDisplayBackend()
        let controller = DisplayController(backend: backend, catalog: [display])
        defer { controller.stop() }
        await controller.refresh()
        #expect(await backend.count() == 0)
        controller.setVisible(true)
        try await waitForReads(backend, 1)
        try await settle(controller)
        #expect(controller.readings[7]?[.volume] == .unsupported)
        // 保护状态前的正常刷新可以增加总次数，之后应验证读取增量。
        await controller.refresh()
        let token = UUID()
        controller.beginEditing(token)
        try await settle(controller)
        await controller.write(20, control: .volume, display: display)
        await controller.write(.nan, control: .brightness, display: display)
        #expect(await backend.writeCount() == 0)
        await controller.write(60, control: .brightness, display: display)
        #expect(await backend.writeCount() == 1)
        #expect(controller.readings[7]?[.brightness] == .value(DDCValue(current: 60, maximum: 100)))
        controller.setVisible(false)
        let readsBeforeHiddenOperations = await backend.count()
        await controller.refresh()
        await controller.write(20, control: .brightness, display: display)
        #expect(await backend.count() == readsBeforeHiddenOperations)
        #expect(await backend.writeCount() == 1)
    }

    @Test func oldReadCannotPublishAfterCloseOrClearNewRequest() async throws {
        let backend = TestDisplayBackend()
        await backend.block()
        let controller = DisplayController(backend: backend, catalog: [display])
        defer { controller.stop() }
        controller.setVisible(true)
        try await waitForReads(backend, 1)
        controller.setVisible(false)
        #expect(await backend.wasCancelled(0))
        controller.setVisible(true)
        try await waitForReads(backend, 2)
        await backend.finish(10)
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.isRefreshing)
        #expect(controller.readings.isEmpty)
        await backend.finish(80)
        try await settle(controller)
        #expect(controller.readings[7]?[.brightness] == .value(DDCValue(current: 80, maximum: 100)))
    }

    @Test func pauseAndWakeSettlingCannotBeBypassedByManualRefreshOrReopen() async throws {
        let backend = TestDisplayBackend()
        let controller = DisplayController(backend: backend, catalog: [display])
        defer { controller.stop() }
        controller.setVisible(true)
        try await waitForReads(backend, 1)
        try await settle(controller)
        await controller.refresh()
        // 冻结后续周期读取并排空已有请求，再进入暂停状态。
        controller.beginEditing(UUID())
        try await settle(controller)
        controller.setPaused(true)
        let readsBeforePausedOperations = await backend.count()
        await controller.refresh()
        await controller.write(20, control: .brightness, display: display)
        #expect(await backend.writeCount() == 0)
        controller.setPaused(false)
        #expect(controller.isSettling)
        controller.setVisible(false)
        controller.setVisible(true)
        await controller.refresh()
        #expect(controller.isSettling)
        // 先结束可见需求，避免断言的异步读取遇到已到期的恢复任务。
        controller.setVisible(false)
        #expect(await backend.count() == readsBeforePausedOperations)
    }

    @Test func failedReadbackIsNotReportedAsSuccessfulAndEditingDefersPolling() async throws {
        let backend = TestDisplayBackend()
        let controller = DisplayController(backend: backend, catalog: [display])
        defer { controller.stop() }
        controller.setVisible(true)
        try await waitForReads(backend, 1)
        try await settle(controller)
        let token = UUID()
        await controller.refresh()
        controller.beginEditing(token)
        defer { controller.endEditing(token) }
        try await settle(controller)
        let readsBeforeEditingRefresh = await backend.count()
        await controller.refresh()
        #expect(await backend.count() == readsBeforeEditingRefresh)
        await backend.setWriteResult(.unconfirmed(nil))
        await controller.write(20, control: .brightness, display: display)
        #expect(controller.readings[7]?[.brightness] == .unconfirmed(nil))
        #expect(!controller.isWriting)
        await controller.write(40, control: .brightness, display: display)
        #expect(await backend.writeCount() == 1)
    }
}
