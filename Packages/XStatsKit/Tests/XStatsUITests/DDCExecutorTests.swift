// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

struct DDCExecutorTests {
    @Test func timeoutDoesNotQueueMoreWorkBehindAHungCall() async throws {
        let backend = NativeDisplayDDC()
        let gate = DispatchSemaphore(value: 0)
        let ticket = DDCCancellation()
        let first = await backend.execute(timeout: -1, busy: -2, cancellation: ticket) {
            gate.wait()
            return 1
        }
        #expect(first == -1)
        #expect(ticket.isCancelled)
        let second = await backend.execute(timeout: -1, busy: -2, cancellation: DDCCancellation()) {
            Issue.record("A timed-out kernel operation must retain its single execution slot")
            return 2
        }
        #expect(second == -2)
        gate.signal()
        var recovered = -2
        let deadline = ContinuousClock.now + .seconds(30)
        while recovered == -2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            recovered = await backend.execute(timeout: -1, busy: -2, cancellation: DDCCancellation()) { 3 }
        }
        #expect(recovered == 3)
    }

    @Test func completedOperationIsNotCancelledByItsExpiredDeadline() async throws {
        let ticket = DDCCancellation()
        let backend = NativeDisplayDDC()
        let value = await backend.execute(timeout: -1, busy: -2, cancellation: ticket) { 7 }
        #expect(value == 7)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(!ticket.isCancelled)
    }
}
