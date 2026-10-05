// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AudioControl

private final class PipelineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.withLock { items.append(item) } }
    var entries: [String] { lock.withLock { items } }
}
private final class TestPipeline: AudioMixPipeline, @unchecked Sendable {
    let processIDs: [UInt32]
    let outputUID: String
    let sourceUID: String?
    let id: String
    let log: PipelineLog
    private let lock = NSLock()
    private var stopFailures: Int
    private let startError: AudioControlError?
    var isOutputPresent: Bool { true }
    var frameCount: UInt64 { 1 } // 只收到首帧，之后不再前进，验证重建预算不会因首帧而重置。
    init(_ target: AudioMixTarget, output: String, source: String?, log: PipelineLog, stopFailures: Int = 0, startFails: Bool = false, startError: AudioControlError? = nil) {
        id = target.id; processIDs = target.processObjectIDs; outputUID = output; sourceUID = source; self.log = log; self.stopFailures = stopFailures; self.startError = startError ?? (startFails ? .renderStalled : nil)
    }
    func matches(_ target: AudioMixTarget, outputUID: String, sourceUID: String?) -> Bool {
        target.id == id && target.processObjectIDs == processIDs && self.outputUID == outputUID && self.sourceUID == sourceUID
    }
    func start(shouldContinue: () -> Bool) throws { log.append("start:\(id):\(outputUID)"); if let startError { throw startError } }
    func setVolume(_ volume: Float) { log.append("gain:\(id)"); log.append("volume:\(id):\(outputUID):\(volume)") }
    func stop() throws {
        log.append("stop:\(id):\(outputUID)")
        let fails = lock.withLock { if stopFailures > 0 { stopFailures -= 1; return true }; return false }
        if fails { throw AudioControlError.hardware(-1) }
    }
}
struct AudioMixerLifecycleTests {
    @Test func aFailedRouteStillUpdatesTheRetainedPipelinesGainWithoutRetrying() async throws {
        let log = PipelineLog()
        let client = AudioMixerClient(automaticHealthChecks: false) {
            TestPipeline($0, output: $1, source: $2, log: log, startError: $1 == "usb" ? .unsupportedFormat : nil)
        }
        let a = try target("a")
        try await client.apply([a], outputUID: "default")
        await #expect(throws: AudioControlError.unsupportedFormat) {
            try await client.apply([try target("a", output: "usb")], outputUID: "default")
        }
        let muted = AudioMixTarget(id: "a", processObjectIDs: [1], volume: try #require(AudioAppVolume(level: 0.5, isMuted: true)), outputUID: "usb")
        await #expect(throws: AudioControlError.unsupportedFormat) { try await client.apply([muted], outputUID: "default") }
        #expect(log.entries.contains("volume:a:default:0.0"))
        let boosted = AudioMixTarget(id: "a", processObjectIDs: [1], volume: try #require(AudioAppVolume(level: 1.6)), outputUID: "usb")
        await #expect(throws: AudioControlError.unsupportedFormat) { try await client.apply([boosted], outputUID: "default") }
        #expect(log.entries.contains("volume:a:default:1.6"))
        #expect(log.entries.filter { $0 == "start:a:usb" }.count == 1)
        #expect(!log.entries.contains("stop:a:default"))
        await client.stop()
    }

    private func target(_ id: String, output: String? = nil) throws -> AudioMixTarget {
        AudioMixTarget(id: id, processObjectIDs: [1], volume: try #require(AudioAppVolume(level: 0.5)), outputUID: output)
    }
    @Test func replacesOnlyTheChangedApplicationAndStartsSilentlyBeforeStoppingItsOldRoute() async throws {
        let log = PipelineLog()
        let client = AudioMixerClient(automaticHealthChecks: false) { TestPipeline($0, output: $1, source: $2, log: log) }
        let a = try target("a"), b = try target("b")
        try await client.apply([a, b], outputUID: "default")
        try await client.apply([try target("a", output: "usb"), b], outputUID: "default")
        let events = log.entries
        #expect(events.filter { $0 == "start:b:default" }.count == 1)
        #expect(!events.contains("stop:b:default"))
        let start = try #require(events.firstIndex(of: "start:a:usb"))
        let stop = try #require(events.firstIndex(of: "stop:a:default"))
        #expect(start < stop)
        #expect(events[stop + 1] == "gain:a")
        await client.stop()
    }
    @Test func failedRetirementBlocksReplacementAndCleanupIsBounded() async throws {
        let log = PipelineLog()
        let client = AudioMixerClient(automaticHealthChecks: false) { TestPipeline($0, output: $1, source: $2, log: log, stopFailures: 100) }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        try await client.apply([try target("a")], outputUID: "default")
        await client.checkHealth(now: now + 2)
        #expect(log.entries.filter { $0 == "start:a:default" }.count == 1)
        await client.checkHealth(now: now + 4)
        await client.checkHealth(now: now + 6)
        let stops = log.entries.filter { $0 == "stop:a:default" }.count
        await client.checkHealth(now: now + 8)
        #expect(log.entries.filter { $0 == "stop:a:default" }.count == stops)
        #expect(log.entries.filter { $0 == "start:a:default" }.count == 1)
        await client.stop()
    }

    @Test func removalFailureBlocksANewAppInTheSameApply() async throws {
        let log = PipelineLog()
        let client = AudioMixerClient(automaticHealthChecks: false) { TestPipeline($0, output: $1, source: $2, log: log, stopFailures: $0.id == "a" ? 100 : 0) }
        try await client.apply([try target("a")], outputUID: "default")
        await #expect(throws: AudioControlError.unavailable) { try await client.apply([try target("b")], outputUID: "default") }
        #expect(!log.entries.contains("start:b:default"))
        await client.stop()
    }
    @Test func aRetirementFailureDoesNotPreventStoppingOtherPausedApps() async throws {
        let log = PipelineLog()
        let client = AudioMixerClient(automaticHealthChecks: false) { TestPipeline($0, output: $1, source: $2, log: log, stopFailures: $0.id == "a" ? 100 : 0) }
        let a = try target("a"), b = try target("b")
        try await client.apply([a, b], outputUID: "default")
        try? await client.apply([b], outputUID: "default")
        try? await client.apply([], outputUID: "default")
        #expect(log.entries.contains("stop:b:default"))
        await client.stop()
    }

    @Test func aDeferredRouteChangeReplacesTheOldRouteAfterCleanup() async throws {
        let log = PipelineLog()
        let client = AudioMixerClient(automaticHealthChecks: false) { TestPipeline($0, output: $1, source: $2, log: log, stopFailures: $0.id == "a" ? 1 : 0) }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        try await client.apply([try target("a"), try target("b")], outputUID: "default")
        try? await client.apply([try target("b", output: "usb")], outputUID: "default")
        #expect(!log.entries.contains("start:b:usb"))
        await client.checkHealth(now: now + 0.5)
        #expect(log.entries.contains("start:b:usb"))
        #expect(log.entries.contains("stop:b:default"))
        await client.stop()
    }
    @Test func realDeferredStartupFailureRemainsBlockedAfterItsCleanupSucceeds() async throws {
        let log = PipelineLog()
        let client = AudioMixerClient(automaticHealthChecks: false) { TestPipeline($0, output: $1, source: $2, log: log, stopFailures: 1, startFails: $0.id == "b") }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        try await client.apply([try target("a")], outputUID: "default")
        try? await client.apply([try target("b")], outputUID: "default")
        await client.checkHealth(now: now + 0.5)
        #expect(log.entries.filter { $0 == "start:b:default" }.count == 1)
        await client.checkHealth(now: now + 1)
        await client.checkHealth(now: now + 2)
        #expect(log.entries.filter { $0 == "start:b:default" }.count == 1)
        await #expect(throws: AudioControlError.renderStalled) { try await client.apply([try target("b")], outputUID: "default") }
        await client.stop()
    }

    @Test func aFrozenReplacementIsReleasedAndNotRebuiltUntilExplicitRetry() async throws {
        let log = PipelineLog()
        let client = AudioMixerClient(automaticHealthChecks: false) { TestPipeline($0, output: $1, source: $2, log: log) }
        let desired = [try target("a")]
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        try await client.apply(desired, outputUID: "default")
        await client.checkHealth(now: now + 2)
        await client.checkHealth(now: now + 4)
        #expect(log.entries.filter { $0 == "start:a:default" }.count == 2)
        await #expect(throws: AudioControlError.renderStalled) { try await client.apply(desired, outputUID: "default") }
        #expect(await client.unresolvedApplicationIDs() == ["a"])
        #expect(log.entries.filter { $0 == "start:a:default" }.count == 2)
        await client.retryFailed()
        try await client.apply(desired, outputUID: "default")
        #expect(await client.unresolvedApplicationIDs().isEmpty)
        #expect(log.entries.filter { $0 == "start:a:default" }.count == 3)
        await client.stop()
        await client.checkHealth(now: now + 8)
        #expect(log.entries.filter { $0 == "start:a:default" }.count == 3)
    }

    @Test func aBatchFailureDoesNotMarkASuccessfulApplicationAsUnresolved() async throws {
        let log = PipelineLog()
        let client = AudioMixerClient(automaticHealthChecks: false) { TestPipeline($0, output: $1, source: $2, log: log, startFails: $0.id == "a") }
        await #expect(throws: AudioControlError.renderStalled) {
            try await client.apply([try target("a"), try target("b", output: "usb")], outputUID: "default")
        }
        #expect(await client.unresolvedApplicationIDs() == ["a"])
        #expect(log.entries.contains("start:b:usb"))
        await client.stop()
    }
}
