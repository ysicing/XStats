// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import SMC

struct FanStartupTests {
    @Test func firmwareStateDoesNotRequireAManualTarget() {
        var tracker = FanStartupTracker()
        let starting = tracker.update(id: 0, current: 0, target: 0, isManual: false, status: 1, now: 0)
        #expect(starting)
    }
    @Test func firmwareStartupIsBoundedAndResetsAfterRotation() {
        var tracker = FanStartupTracker()
        let result1 = tracker.update(id: 0, current: 0, target: 2000, isManual: false, status: 1, now: 100)
        #expect(result1)
        let result2 = tracker.update(id: 0, current: 0, target: 2000, isManual: false, status: 1, now: 105)
        #expect(result2)
        let result3 = tracker.update(id: 0, current: 0, target: 2000, isManual: false, status: 1, now: 111)
        #expect(!result3)
        let result4 = tracker.update(id: 0, current: 0, target: 2500, isManual: false, status: 1, now: 112)
        #expect(!result4)
        let result5 = tracker.update(id: 0, current: 1500, target: 2000, isManual: false, status: 5, now: 113)
        #expect(!result5)
        let result6 = tracker.update(id: 0, current: 0, target: 2000, isManual: false, status: 1, now: 114)
        #expect(result6)
    }

    @Test func fallbackRequiresManualTargetAndDoesNotHideStoppedFans() {
        var tracker = FanStartupTracker()
        let result7 = tracker.update(id: 0, current: 0, target: 2000, isManual: false, status: nil, now: 1)
        #expect(!result7)
        let result8 = tracker.update(id: 0, current: 0, target: 0, isManual: true, status: nil, now: 2)
        #expect(!result8)
        let result9 = tracker.update(id: 1, current: 0, target: 2000, isManual: true, status: 3, now: 3)
        #expect(!result9)
        let result10 = tracker.update(id: 0, current: 0, target: 2000, isManual: true, status: nil, now: 4)
        #expect(result10)
        let result11 = tracker.update(id: 0, current: 0, target: 2000, isManual: true, status: nil, now: 14)
        #expect(!result11)
        let result12 = tracker.update(id: 0, current: 0, target: 2000, isManual: true, status: nil, now: 50)
        #expect(!result12)
    }

    @Test func eachFanHasAnIndependentStartupWindow() {
        var tracker = FanStartupTracker()
        let result13 = tracker.update(id: 0, current: 0, target: 2000, isManual: true, status: nil, now: 10)
        #expect(result13)
        let result14 = tracker.update(id: 1, current: 0, target: 2000, isManual: true, status: nil, now: 15)
        #expect(result14)
        tracker.retain(fanCount: 2)
        let result15 = tracker.update(id: 0, current: 0, target: 2000, isManual: true, status: nil, now: 20)
        #expect(!result15)
        let result16 = tracker.update(id: 1, current: 0, target: 2000, isManual: true, status: nil, now: 20)
        #expect(result16)
        tracker.retain(fanCount: 0)
        let result17 = tracker.update(id: 0, current: 0, target: 2000, isManual: true, status: nil, now: 21)
        #expect(result17)
    }

    @Test func transientStatusFailureKeepsTheFirmwareWindow() {
        var tracker = FanStartupTracker()
        let initiallyStarting = tracker.update(id: 0, current: 0, target: 0, isManual: false, status: 1, now: 0)
        #expect(initiallyStarting)
        let duringFailure = tracker.update(id: 0, current: 0, target: 0, isManual: false, status: nil, now: 5)
        #expect(duringFailure)
        let expiredDuringFailure = tracker.update(id: 0, current: 0, target: 0, isManual: false, status: nil, now: 11)
        #expect(!expiredDuringFailure)
        let afterRecovery = tracker.update(id: 0, current: 0, target: 0, isManual: false, status: 1, now: 12)
        #expect(!afterRecovery)
        let failureWithManualTarget = tracker.update(id: 0, current: 0, target: 2000, isManual: true, status: nil, now: 13)
        #expect(!failureWithManualTarget)
    }

    @Test func failedFanCountDoesNotRestartAnExpiredWindow() {
        var tracker = FanStartupTracker()
        let initiallyStarting = tracker.update(id: 0, current: 0, target: 2000, isManual: true, status: nil, now: 0)
        #expect(initiallyStarting)
        tracker.retain(fanCount: nil)
        tracker.retain(fanCount: 1)
        let afterReadFailure = tracker.update(id: 0, current: 0, target: 2000, isManual: true, status: nil, now: 11)
        #expect(!afterReadFailure)
        tracker.retain(fanCount: nil)
        let afterRepeatedFailure = tracker.update(id: 0, current: 0, target: 2000, isManual: true, status: nil, now: 20)
        #expect(!afterRepeatedFailure)
    }
}

struct FanStartupSummaryTests {
    private func fan(_ id: Int, current: Double, starting: Bool = false) -> FanState {
        FanState(id: id, current: current, minimum: 1000, maximum: 5000, target: 2000, isManual: true, isStarting: starting)
    }

    @Test func spinningFanKeepsSummaryWhileAnotherStarts() {
        #expect(![fan(0, current: 2400), fan(1, current: 0, starting: true)].isStartingUp)
    }

    @Test func summaryStartsOnlyWhenNoFanSpins() {
        #expect([fan(0, current: 0), fan(1, current: 0, starting: true)].isStartingUp)
        #expect(![fan(0, current: 0), fan(1, current: 0)].isStartingUp)
        #expect(![FanState]().isStartingUp)
    }
}
