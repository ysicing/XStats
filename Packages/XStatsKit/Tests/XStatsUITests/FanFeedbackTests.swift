// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Metrics
@testable import SMC
import Testing
@testable import XStatsUI

@MainActor private final class FanFeedbackFixture: FanControlClient {
    var writes: [(Int, Double)] = []
    var error: String?
    /// 复位结果独立于写入结果，才能区分“写入失败但已回到自动”和“兜底复位也失败”。
    var resetError: String?
    var holdWrite = false
    var writeContinuation: CheckedContinuation<String?, Never>?
    var holdRead = false
    var readContinuation: CheckedContinuation<[FanState]?, Never>?
    var reads = 0
    var reading: [FanState] = []

    func setFanTarget(fan: Int, rpm: Double) async -> String? {
        writes.append((fan, rpm))
        if holdWrite { return await withCheckedContinuation { writeContinuation = $0 } }
        return error
    }
    func resetAllFans() async -> String? { resetError }
    func read() async -> [FanState]? {
        reads += 1
        if holdRead { return await withCheckedContinuation { readContinuation = $0 } }
        return reading
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FanFeedbackTests {
    @Test func fanOnlyUpdatesPreserveTemperaturesAndDoNotAdvanceHistory() {
        let store = MetricsStore(readBattery: false)
        var snapshot = MetricsSnapshot()
        snapshot.sensors = SensorReadings(temperatures: [
            TemperatureSummary(group: .cpu, average: 45, maximum: 50, sensorCount: 4)
        ], fans: [fan(1_000)], fanCount: 1)
        store.apply(snapshot)
        let updatedAt = store.lastUpdate
        store.updateFans([fan(2_500)])
        #expect(store.fastestFan?.current == 2_500)
        #expect(store.sensors?.temperature(.cpu)?.maximum == 50)
        #expect(store.fanCount == 1 && store.lastUpdate == updatedAt)
        #expect(store.cpuTotal.elements.isEmpty && store.powerHistory.elements.isEmpty)
        store.updateFans([])
        #expect(store.fastestFan?.current == 2_500)
    }

    @Test func successfulSwitchPublishesMeasuredRPMAndStopsAtTarget() async throws {
        let fixture = FanFeedbackFixture()
        fixture.reading = [fan(5_000)]
        try await withController(fixture) { controller, store in
            controller.setFeedbackVisible(true)
            await controller.select(.maximum)
            try await waitUntil { store.fastestFan?.current == 5_000 }
            #expect(controller.mode == .maximum && !controller.noticeIsError)
            #expect(fixture.writes.count == 1 && fixture.writes.first?.1 == 5_000)
            try await Task.sleep(for: .milliseconds(650))
            #expect(fixture.reads == 1)
        }
    }

    @Test(arguments: [false, true]) func hidingOrPausingRejectsInFlightFeedback(paused: Bool) async throws {
        let fixture = FanFeedbackFixture()
        fixture.holdRead = true
        try await withController(fixture) { controller, store in
            controller.setFeedbackVisible(true)
            await controller.select(.maximum)
            try await waitUntil { fixture.readContinuation != nil }
            if paused { controller.setPaused(true) } else { controller.setFeedbackVisible(false) }
            fixture.readContinuation?.resume(returning: [fan(4_000)])
            fixture.readContinuation = nil
            try await Task.sleep(for: .milliseconds(650))
            #expect(store.fastestFan?.current == 1_000 && fixture.reads == 1)
            #expect(controller.mode == .maximum)
        }
    }

    @Test func newerSwitchRejectsOldReadingAndSerializesWrites() async throws {
        let fixture = FanFeedbackFixture()
        fixture.holdRead = true
        try await withController(fixture) { controller, store in
            controller.setFeedbackVisible(true)
            await controller.select(.maximum)
            try await waitUntil { fixture.readContinuation != nil }
            fixture.holdWrite = true
            let next = Task { await controller.select(.cooling) }
            try await waitUntil { fixture.writeContinuation != nil }
            await controller.select(.custom)
            #expect(controller.mode == .cooling && fixture.writes.count == 2)
            fixture.readContinuation?.resume(returning: [fan(4_900)])
            fixture.readContinuation = nil
            fixture.holdRead = false
            fixture.reading = [fan(3_400)]
            fixture.writeContinuation?.resume(returning: nil)
            fixture.writeContinuation = nil
            await next.value
            try await waitUntil { store.fastestFan?.current == 3_400 }
            #expect(fixture.reads == 2 && controller.mode == .cooling)
        }
    }

    /// 模式键读不到时不能确认已交还系统，跟踪必须继续读取；读到且一致时才在首次读取后结束。
    @Test(arguments: [true, false]) func automaticFeedbackNeverConfirmsAnUnreadModeKey(modeKnown: Bool) async throws {
        let fixture = FanFeedbackFixture()
        fixture.reading = [fan(5_000)]
        try await withController(fixture) { controller, store in
            controller.setFeedbackVisible(true)
            await controller.select(.maximum)
            try await waitUntil { store.fastestFan?.current == 5_000 }
            try await Task.sleep(for: .milliseconds(650))
            #expect(fixture.reads == 1)

            fixture.reading = [FanState(id: 0, current: 1_200, minimum: 1_000, maximum: 5_000, target: 1_200,
                                        isManual: false, isModeKnown: modeKnown)]
            await controller.select(.automatic)
            try await waitUntil { fixture.reads >= 2 }
            try await Task.sleep(for: .milliseconds(1_200))
            if modeKnown {
                #expect(fixture.reads == 2)
            } else {
                #expect(fixture.reads >= 3)
            }
        }
    }

    @Test func failedOrInvisibleCommandsDoNotStartFeedback() async throws {
        let fixture = FanFeedbackFixture()
        try await withController(fixture) { controller, store in
            await controller.select(.maximum)
            try await Task.sleep(for: .milliseconds(50))
            #expect(fixture.reads == 0 && store.fastestFan?.current == 1_000)
            controller.setFeedbackVisible(true)
            fixture.error = "fixture-write-failure"
            await controller.select(.cooling)
            try await Task.sleep(for: .milliseconds(50))
            #expect(fixture.reads == 0 && controller.mode == .maximum && controller.noticeIsError)
        }
    }

    /// 写入失败后的兜底复位也失败时，硬件可能仍被手动接管；不能回滚成“自动”让界面掩盖这一点。
    @Test func failedFallbackResetKeepsTheManualStateInsteadOfShowingAutomatic() async throws {
        let fixture = FanFeedbackFixture()
        fixture.error = "fixture-write-failure"
        fixture.resetError = "fixture-reset-failure"
        try await withController(fixture) { controller, _ in
            await controller.select(.maximum)
            #expect(controller.mode == .maximum && controller.noticeIsError)
            #expect(controller.notice == "fixture-reset-failure")
        }
    }

    @Test func failedWriteWithSuccessfulFallbackResetRollsBackToThePreviousMode() async throws {
        let fixture = FanFeedbackFixture()
        fixture.error = "fixture-write-failure"
        try await withController(fixture) { controller, _ in
            await controller.select(.maximum)
            #expect(controller.mode == .automatic && controller.noticeIsError)
            #expect(controller.notice == "fixture-write-failure")
        }
    }

    @Test func customTargetCannotChangeDuringAnOutstandingWrite() async throws {
        let fixture = FanFeedbackFixture()
        try await withController(fixture) { controller, _ in
            controller.customLevel = 0.1
            fixture.holdWrite = true
            let command = Task { await controller.select(.custom) }
            try await waitUntil { fixture.writeContinuation != nil }
            controller.customLevel = 1
            await controller.commitCustomLevel()
            #expect(controller.customLevel == 0.1)
            #expect(fixture.writes.count == 1 && fixture.writes.first?.1 == 1_400)
            fixture.writeContinuation?.resume(returning: nil)
            fixture.writeContinuation = nil
            await command.value
            controller.evaluateSafety(temperature: 110)
            try await waitUntil { controller.mode == .automatic && !controller.isApplying }
            #expect(!controller.noticeIsError)
        }
    }

    @Test func unchangedRPMHasABoundedReadBudget() async throws {
        let fixture = FanFeedbackFixture()
        fixture.reading = [fan(1_100)]
        try await withController(fixture) { controller, store in
            controller.setFeedbackVisible(true)
            await controller.select(.maximum)
            // 转速始终达不到目标，跟踪循环按 500ms 间隔重读，直到 20 次或 10 秒上限。
            // 2 秒内应只有 4~5 次读取；上界放宽到 8 容忍调度抖动，但仍能发现间隔丢失
            // （无节流时 20 次预算会在这段时间内被瞬间耗尽）。
            try await Task.sleep(for: .seconds(2))
            let count = fixture.reads
            #expect((2...8).contains(count) && store.fastestFan?.current == 1_100)
            // 关闭反馈后循环必须停止，不再消耗读取预算。
            controller.setFeedbackVisible(false)
            try await Task.sleep(for: .milliseconds(650))
            #expect(fixture.reads == count)
        }
    }

    private func withController(_ fixture: FanFeedbackFixture,
                                body: (FanController, MetricsStore) async throws -> Void) async throws {
        let name = "FanFeedbackTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let store = MetricsStore(readBattery: false)
        var snapshot = MetricsSnapshot()
        snapshot.sensors = SensorReadings(temperatures: [], fans: [fan(1_000)], fanCount: 1)
        store.apply(snapshot)
        let controller = FanController(helper: fixture, store: store, settings: settings, readFans: { await fixture.read() })
        defer { controller.setFeedbackVisible(false) }
        try await body(controller, store)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func fan(_ rpm: Double) -> FanState {
        FanState(id: 0, current: rpm, minimum: 1_000, maximum: 5_000, target: 5_000, isManual: true)
    }
}
