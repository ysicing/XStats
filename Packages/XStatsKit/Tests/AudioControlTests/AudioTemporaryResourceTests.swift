// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AudioControl

private final class TemporaryAudioLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var entries: [String] { lock.withLock { values } }
}

private final class TestAccessProbe: AudioAccessProbe {
    let log: TemporaryAudioLog
    let startError: AudioControlError?
    private var stopFailures: Int
    private let onStart: @Sendable () -> Void
    init(log: TemporaryAudioLog, startError: AudioControlError? = nil, stopFailures: Int = 0, onStart: @escaping @Sendable () -> Void = {}) {
        self.log = log; self.startError = startError; self.stopFailures = stopFailures; self.onStart = onStart
    }
    func start(shouldContinue: () -> Bool) throws {
        log.append("read")
        onStart()
        if !shouldContinue() { throw CancellationError() }
        if let startError { throw startError }
    }
    func stop() throws {
        log.append("stop:probe")
        if stopFailures > 0 { stopFailures -= 1; throw AudioControlError.hardware(-1) }
    }
}

private final class TestOutputGuard: AudioOutputSwitchGuard {
    let id: UInt32 = 42
    let log: TemporaryAudioLog
    private var failures: Int
    init(log: TemporaryAudioLog, failures: Int) { self.log = log; self.failures = failures }
    func stop() throws {
        log.append("destroy:guard")
        if failures > 0 { failures -= 1; throw AudioControlError.hardware(-1) }
        log.append("removed:guard")
    }
}

private final class GuardedTestPipeline: AudioMixPipeline {
    let processIDs: [UInt32] = [1]
    let frameCount: UInt64 = 1
    let outputUID = "default"
    let isOutputPresent = true
    let log: TemporaryAudioLog
    init(log: TemporaryAudioLog) { self.log = log }
    func matches(_ target: AudioMixTarget, outputUID: String, sourceUID: String?) -> Bool { outputUID == self.outputUID }
    func start(shouldContinue: () -> Bool) throws { }
    func setVolume(_ volume: Float) { }
    func stop() throws { log.append("stop:pipeline") }
}

struct AudioTemporaryResourceTests {
    @Test func cancelledActivationRejectsTheLateResultAndStopsItsProbe() async throws {
        let log = TemporaryAudioLog()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let client = AudioMixerClient(automaticHealthChecks: false, accessProbeFactory: {
            TestAccessProbe(log: log, onStart: {
                signal.yield(()); signal.finish()
                _ = release.wait(timeout: .now() + 2)
            })
        }) { _, _, _ in GuardedTestPipeline(log: log) }
        let operation = Task { try await client.requestAccess() }
        for await _ in started { break }
        operation.cancel(); release.signal()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(log.entries == ["read", "stop:probe"])
        await client.stop()
    }

    @Test func failedProbeCleanupIsRetainedUntilManualRetry() async throws {
        let log = TemporaryAudioLog()
        let client = AudioMixerClient(automaticHealthChecks: false, accessProbeFactory: { TestAccessProbe(log: log, stopFailures: 3) }) { _, _, _ in GuardedTestPipeline(log: log) }
        await #expect(throws: AudioControlError.hardware(-1)) { try await client.requestAccess() }
        await client.checkHealth(now: 1)
        await client.checkHealth(now: 2)
        let stopped = log.entries.filter { $0 == "stop:probe" }.count
        #expect(stopped == 3)
        await client.checkHealth(now: 3)
        #expect(log.entries.filter { $0 == "stop:probe" }.count == stopped)
        await client.retryFailed()
        #expect(log.entries.filter { $0 == "stop:probe" }.count == 4)
        await client.stop()
    }
    @Test func activationStartsReadingBeforeReturningAndReleasesTheProbe() async throws {
        let log = TemporaryAudioLog()
        let client = AudioMixerClient(automaticHealthChecks: false, accessProbeFactory: { TestAccessProbe(log: log) }) { _, _, _ in GuardedTestPipeline(log: log) }
        try await client.requestAccess()
        #expect(log.entries == ["read", "stop:probe"])
        await client.stop()
    }

    @Test func deniedActivationDoesNotReturnSuccessAndStillReleasesItsProbe() async throws {
        let log = TemporaryAudioLog()
        let client = AudioMixerClient(automaticHealthChecks: false, accessProbeFactory: { TestAccessProbe(log: log, startError: .permissionRequired) }) { _, _, _ in GuardedTestPipeline(log: log) }
        await #expect(throws: AudioControlError.permissionRequired) { try await client.requestAccess() }
        #expect(log.entries == ["read", "stop:probe"])
        await client.stop()
    }

    @Test func aFailedTransitionGuardIsRetainedForBoundedCleanup() async throws {
        let log = TemporaryAudioLog()
        let client = AudioMixerClient(automaticHealthChecks: false, outputGuardFactory: { _ in TestOutputGuard(log: log, failures: 100) }) { _, _, _ in GuardedTestPipeline(log: log) }
        let target = AudioMixTarget(id: "a", processObjectIDs: [1], volume: try #require(AudioAppVolume(level: 0.5)))
        try await client.apply([target], outputUID: "default")
        let guardID = try #require(try await client.prepareOutputSwitch())
        await #expect(throws: AudioControlError.hardware(-1)) { try await client.finishOutputSwitch(guardID) }
        await client.checkHealth(now: 1)
        await client.checkHealth(now: 2)
        let attempts = log.entries.filter { $0 == "destroy:guard" }.count
        #expect(attempts == 3)
        await client.checkHealth(now: 3)
        #expect(log.entries.filter { $0 == "destroy:guard" }.count == attempts)
        await client.retryFailed()
        #expect(log.entries.filter { $0 == "destroy:guard" }.count > attempts)
        await client.stop()
    }

    @Test func disablingDuringATransitionStillOwnsAndDestroysItsGuard() async throws {
        let log = TemporaryAudioLog()
        let client = AudioMixerClient(automaticHealthChecks: false, outputGuardFactory: { _ in TestOutputGuard(log: log, failures: 0) }) { _, _, _ in GuardedTestPipeline(log: log) }
        let target = AudioMixTarget(id: "a", processObjectIDs: [1], volume: try #require(AudioAppVolume(level: 0.5)))
        try await client.apply([target], outputUID: "default")
        let guardID = try #require(try await client.prepareOutputSwitch())
        await client.stop()
        #expect(log.entries.contains("removed:guard"))
        try await client.finishOutputSwitch(guardID)
        #expect(log.entries.filter { $0 == "removed:guard" }.count == 1)
    }
}
