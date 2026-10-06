// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security
import Testing
@testable import NetworkObservation

@Suite(.timeLimit(.minutes(1)))
struct ObservationServiceHostTests {
    private func peer(_ listener: NSXPCListener) -> NSXPCConnection {
        let peer = NSXPCConnection(listenerEndpoint: listener.endpoint)
        peer.remoteObjectInterface = NSXPCInterface(with: NetworkObservationService.self)
        peer.resume()
        return peer
    }

    private func read(_ peer: NSXPCConnection, cursor: Int64 = 0, epoch: String = "") async throws -> ObservationBatch {
        let reply = NetworkMonitorReply()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            reply.install(continuation)
            let proxy = peer.remoteObjectProxyWithErrorHandler { @Sendable error in reply.finish(.failure(error)) } as! NetworkObservationService
            proxy.readEvents(after: cursor, epoch: epoch) { data in reply.finish(.success(data)) }
        }
        return try ObservationBatch.decode(data)
    }

    private func diagnostics(_ peer: NSXPCConnection, window: Double) async throws -> FlowDiagnosticsDTO {
        let reply = NetworkMonitorReply()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            reply.install(continuation)
            let proxy = peer.remoteObjectProxyWithErrorHandler { @Sendable error in reply.finish(.failure(error)) } as! NetworkObservationService
            proxy.flowDiagnostics(windowSeconds: window) { @Sendable data in reply.finish(.success(data)) }
        }
        return try JSONDecoder().decode(FlowDiagnosticsDTO.self, from: data)
    }

    @Test func leaseIsAReusedOneShotAndOldDeadlineCannotRevokeRenewal() async throws {
        let listener = NSXPCListener.anonymous()
        let clock = LeaseClockFixture(), timers = LeaseTimerFactory()
        let host = ObservationServiceHost(listener: listener, requiredClientCode: try requirement(),
                                          now: clock.read, makeDeadline: timers.make)
        let generation = host.startFilter()
        defer { host.beginStoppingFilter(generation: generation); listener.invalidate() }
        let reader = peer(listener)
        defer { reader.invalidate() }
        #expect(timers.count == 0, "没有 reader 时不能创建截止源")
        let before = try await read(reader)
        #expect(host.currentDemand.isActive)
        #expect(timers.count == 1)
        clock.set(104)
        _ = try await read(reader)
        #expect(timers.count == 1 && timers.timer(0).schedules == 2)
        clock.set(106)
        timers.timer(0).fire()
        #expect(host.currentDemand.isActive, "旧截止已排队也不得撤销104秒续期后的租约")
        let event = ObservedConnection(id: UUID(), timestamp: Date(), processID: 1, executablePath: "fixture",
                                       address: nil, hostname: nil, port: nil, transport: .tcp, direction: .outbound)
        host.buffer.record(event, now: 107)
        clock.set(110)
        timers.timer(0).fire()
        #expect(!host.currentDemand.isActive && timers.timer(0).cancelled)
        host.buffer.close(event.id)
        clock.set(112)
        let resumed = try await read(reader)
        #expect(resumed.epoch == before.epoch, "到期只停止新流观察，不清历史")
        #expect(resumed.events.count == 2 && resumed.events.last?.closedAt != nil)
        #expect(resumed.activeIDs?.isEmpty == true)
        #expect(timers.count == 2, "到期源已销毁，恢复才创建新的一次性源")
    }

    @Test func diagnosticClientDoesNotBecomeReaderAndReplacedReaderCannotEndNewLease() async throws {
        let listener = NSXPCListener.anonymous()
        let host = ObservationServiceHost(listener: listener, requiredClientCode: try requirement())
        let generation = host.startFilter()
        defer { host.beginStoppingFilter(generation: generation); listener.invalidate() }
        let first = peer(listener), second = peer(listener), diagnostic = peer(listener)
        defer { first.invalidate(); second.invalidate(); diagnostic.invalidate() }
        let baseline = try await diagnostics(diagnostic, window: 30)
        #expect(!host.currentDemand.isActive && !host.buffer.isObserving())
        _ = try await read(first)
        _ = try await diagnostics(diagnostic, window: 0)
        _ = try await read(first)
        _ = try await read(second)
        first.invalidate()
        _ = try await read(second)
        #expect(host.currentDemand.isActive)
        #expect(try await diagnostics(diagnostic, window: 0).token == baseline.token)
    }

    @Test func invalidReadDoesNotTakeLeaseAndLateOldGenerationDeadlineIsIgnored() async throws {
        let listener = NSXPCListener.anonymous()
        let clock = LeaseClockFixture(), timers = LeaseTimerFactory()
        let host = ObservationServiceHost(listener: listener, requiredClientCode: try requirement(),
                                          now: clock.read, makeDeadline: timers.make)
        let old = host.startFilter()
        let first = peer(listener)
        defer { first.invalidate(); listener.invalidate() }
        await #expect(throws: (any Error).self) { _ = try await read(first, cursor: -1) }
        #expect(!host.currentDemand.isActive && timers.count == 0)
        _ = try await read(first)
        host.beginStoppingFilter(generation: old)
        let current = host.startFilter()
        let second = peer(listener)
        defer { second.invalidate(); host.beginStoppingFilter(generation: current) }
        clock.set(200)
        _ = try await read(second)
        clock.set(205)
        timers.timer(0).fire()
        #expect(host.currentDemand.isActive && host.currentDemand.generation == current)
    }

    private func requirement() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        #expect(SecCodeCopySelf([], &code) == errSecSuccess)
        let own = try #require(code)
        #expect(SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess)
        #expect(SecCodeCopyDesignatedRequirement(try #require(staticCode), [], &requirement) == errSecSuccess)
        #expect(SecRequirementCopyString(try #require(requirement), [], &text) == errSecSuccess)
        return try #require(text) as String
    }

    private func stopped(_ peer: NSXPCConnection) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let proxy = peer.remoteObjectProxyWithErrorHandler { @Sendable error in continuation.resume(throwing: error) } as! NetworkObservationService
            proxy.isFilterStopped { @Sendable value in continuation.resume(returning: value) }
        }
    }

    @Test func lifecycleRepliesStayAvailableAfterStopAndClientReplacementCannotConfirmStop() async throws {
        let listener = NSXPCListener.anonymous()
        let host = ObservationServiceHost(listener: listener, requiredClientCode: try requirement())
        defer { listener.invalidate() }
        let generation = host.startFilter()
        let first = NSXPCConnection(listenerEndpoint: listener.endpoint)
        first.remoteObjectInterface = NSXPCInterface(with: NetworkObservationService.self)
        first.resume()
        defer { first.invalidate() }
        #expect(try await stopped(first) == false)
        let second = NSXPCConnection(listenerEndpoint: listener.endpoint)
        second.remoteObjectInterface = NSXPCInterface(with: NetworkObservationService.self)
        second.resume()
        defer { second.invalidate() }
        #expect(try await stopped(second) == false)
        #expect(host.isFilterStopped == false)
        host.beginStoppingFilter(generation: generation)
        #expect(try await stopped(second) == false, "完成 stopFilter 前不能确认停止")
        host.finishStoppingFilter(generation: generation)
        #expect(try await stopped(second) == true)
    }

    @Test func lateStopCompletionCannotConfirmANewerFilterGeneration() throws {
        let listener = NSXPCListener.anonymous()
        let host = ObservationServiceHost(listener: listener, requiredClientCode: try requirement())
        defer { listener.invalidate() }
        let old = host.startFilter()
        host.beginStoppingFilter(generation: old)
        let current = host.startFilter()
        host.finishStoppingFilter(generation: old)
        #expect(host.isFilterStopped == false)
        host.beginStoppingFilter(generation: current)
        host.finishStoppingFilter(generation: current)
        #expect(host.isFilterStopped == true)
    }
}

private final class LeaseClockFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 100
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
    func set(_ value: TimeInterval) { lock.lock(); now = value; lock.unlock() }
}
private final class LeaseTimerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [LeaseTimerFixture] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return timers.count }
    func timer(_ index: Int) -> LeaseTimerFixture { lock.lock(); defer { lock.unlock() }; return timers[index] }
    func make(handler: @escaping @Sendable () -> Void) -> any ObservationLeaseDeadline {
        let timer = LeaseTimerFixture(handler: handler)
        lock.lock(); timers.append(timer); lock.unlock()
        return timer
    }
}
private final class LeaseTimerFixture: ObservationLeaseDeadline, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable () -> Void
    private var scheduleCount = 0
    private var isCancelled = false
    var schedules: Int { lock.lock(); defer { lock.unlock() }; return scheduleCount }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }
    init(handler: @escaping @Sendable () -> Void) { self.handler = handler }
    func schedule(after seconds: TimeInterval) { lock.lock(); scheduleCount += 1; lock.unlock() }
    func cancel() { lock.lock(); isCancelled = true; lock.unlock() }
    func fire() { handler() }
}
