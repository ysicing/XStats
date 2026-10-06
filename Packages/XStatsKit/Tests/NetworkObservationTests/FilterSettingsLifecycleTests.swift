// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import NetworkObservation

struct FilterSettingsLifecycleTests {
    @Test func stopBeforeStartCompletesWithoutCallingSDK() {
        let fixture = FilterApplyFixture()
        let lifecycle = FilterSettingsLifecycle(apply: fixture.apply)
        lifecycle.stop(generation: 0) { fixture.mark() }
        #expect(fixture.modes.isEmpty)
        #expect(fixture.marks == 1)
    }

    @Test func appliesAllowFirstAndSerializesDemandChangesWhileApplyIsPending() {
        let fixture = FilterApplyFixture()
        let lifecycle = FilterSettingsLifecycle(apply: fixture.apply)
        lifecycle.start(generation: 1) { _ in }
        #expect(fixture.modes == [false])
        lifecycle.setDemand(.init(generation: 1, revision: 1, isActive: true))
        #expect(fixture.modes == [false])
        fixture.complete(0)
        #expect(fixture.modes == [false, true])
        lifecycle.setDemand(.init(generation: 1, revision: 2, isActive: false))
        #expect(fixture.modes == [false, true])
        fixture.complete(1)
        #expect(fixture.modes == [false, true, false])
        fixture.complete(2)
        #expect(lifecycle.appliedObservation == false)
    }

    @Test func oldDemandRevisionCannotRevokeTheNewReader() {
        let fixture = FilterApplyFixture()
        let lifecycle = FilterSettingsLifecycle(apply: fixture.apply)
        lifecycle.start(generation: 1) { _ in }
        fixture.complete(0)
        lifecycle.setDemand(.init(generation: 1, revision: 3, isActive: true))
        fixture.complete(1)
        lifecycle.setDemand(.init(generation: 1, revision: 2, isActive: false))
        lifecycle.setDemand(.init(generation: 1, revision: 4, isActive: true))
        #expect(fixture.modes == [false, true])
        #expect(lifecycle.appliedObservation == true)
    }

    @Test func lateApplyAndStopCannotMutateANewerGeneration() {
        let fixture = FilterApplyFixture()
        let lifecycle = FilterSettingsLifecycle(apply: fixture.apply)
        lifecycle.start(generation: 1) { _ in }
        lifecycle.setDemand(.init(generation: 1, revision: 1, isActive: true))
        lifecycle.stop(generation: 1) {}
        lifecycle.start(generation: 2) { _ in }
        lifecycle.setDemand(.init(generation: 2, revision: 1, isActive: true))
        #expect(fixture.modes == [false])
        fixture.complete(0)
        #expect(fixture.modes == [false, false], "新一代必须先独立确认 allow 基线")
        fixture.complete(1)
        #expect(fixture.modes == [false, false, true])
        fixture.complete(2)
        lifecycle.stop(generation: 1) {}
        lifecycle.setDemand(.init(generation: 1, revision: 99, isActive: false))
        #expect(lifecycle.appliedObservation == true)
        #expect(fixture.modes.count == 3)
    }

    @Test func stopWaitsForPendingApplyAndFinalAllowWithoutARepeatedApply() {
        let fixture = FilterApplyFixture()
        let lifecycle = FilterSettingsLifecycle(apply: fixture.apply)
        let completion = FilterApplyFixture()
        lifecycle.start(generation: 1) { _ in }
        fixture.complete(0)
        lifecycle.setDemand(.init(generation: 1, revision: 1, isActive: true))
        lifecycle.stop(generation: 1) { completion.mark() }
        #expect(completion.marks == 0)
        fixture.complete(1)
        #expect(fixture.modes == [false, true, false])
        #expect(completion.marks == 0)
        fixture.complete(2)
        #expect(completion.marks == 1)
        #expect(lifecycle.appliedObservation == false)
    }

    @Test func applyFailureIsReportedAndDoesNotBusyRetry() {
        let fixture = FilterApplyFixture()
        let errors = FilterApplyFixture()
        let lifecycle = FilterSettingsLifecycle(apply: fixture.apply, onError: { _, _, _ in errors.mark() })
        lifecycle.start(generation: 1) { _ in }
        fixture.complete(0)
        lifecycle.setDemand(.init(generation: 1, revision: 1, isActive: true))
        fixture.complete(1)
        lifecycle.setDemand(.init(generation: 1, revision: 2, isActive: false))
        fixture.complete(2, error: CocoaError(.fileReadUnknown))
        #expect(errors.marks == 1)
        #expect(fixture.modes == [false, true, false])
        #expect(lifecycle.appliedObservation == true, "失败不能声称系统已切换为 allow")
    }

    @Test func initialFailureWithAnEarlyReaderFailsStartWithoutRetrying() {
        let fixture = FilterApplyFixture()
        let completed = FilterApplyFixture()
        let lifecycle = FilterSettingsLifecycle(apply: fixture.apply)
        lifecycle.start(generation: 1) { error in if error != nil { completed.mark() } }
        lifecycle.setDemand(.init(generation: 1, revision: 1, isActive: true))
        fixture.complete(0, error: CocoaError(.fileReadUnknown))
        #expect(completed.marks == 1)
        #expect(fixture.modes == [false], "启动 allow 失败后不能因提前读取而自动重试")
    }

    @Test func obsoletePauseWhileApplyIsPendingDoesNotCauseAnExtraSettingsCycle() {
        let fixture = FilterApplyFixture()
        let lifecycle = FilterSettingsLifecycle(apply: fixture.apply)
        lifecycle.start(generation: 1) { _ in }
        fixture.complete(0)
        lifecycle.setDemand(.init(generation: 1, revision: 1, isActive: true))
        lifecycle.setDemand(.init(generation: 1, revision: 2, isActive: false))
        lifecycle.setDemand(.init(generation: 1, revision: 3, isActive: true))
        fixture.complete(1)
        #expect(fixture.modes == [false, true])
        #expect(lifecycle.appliedObservation == true)
    }

    @Test func concurrentDemandUpdatesRemainSerialAndKeepTheNewestRevision() {
        let fixture = FilterApplyFixture()
        let lifecycle = FilterSettingsLifecycle(apply: fixture.apply)
        lifecycle.start(generation: 1) { _ in }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            lifecycle.setDemand(.init(generation: 1, revision: UInt64(index + 1), isActive: index % 2 == 1))
        }
        #expect(fixture.modes == [false])
        fixture.complete(0)
        #expect(fixture.modes == [false, true])
        fixture.complete(1)
        #expect(lifecycle.appliedObservation == true)
    }
}

private final class FilterApplyFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(Bool, @Sendable ((any Error)?) -> Void)] = []
    private var count = 0
    var modes: [Bool] { lock.lock(); defer { lock.unlock() }; return requests.map(\.0) }
    var marks: Int { lock.lock(); defer { lock.unlock() }; return count }
    func mark() { lock.lock(); count += 1; lock.unlock() }
    func apply(_ observing: Bool, completion: @escaping @Sendable ((any Error)?) -> Void) {
        lock.lock(); requests.append((observing, completion)); lock.unlock()
    }
    func complete(_ index: Int, error: (any Error)? = nil) {
        lock.lock(); let completion = requests[index].1; lock.unlock()
        completion(error)
    }
}
