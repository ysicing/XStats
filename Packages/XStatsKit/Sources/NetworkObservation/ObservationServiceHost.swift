// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 生命周期查询与进程同寿命；成员校验、租约和需求序号共用一把锁，外部回调在锁外。
public final class ObservationServiceHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public let buffer = ObservationBuffer()
    private let lock = NSLock()
    private let listener: NSXPCListener
    private let requiredClientCode: String
    private let now: @Sendable () -> TimeInterval
    private let makeDeadline: @Sendable (@escaping @Sendable () -> Void) -> any ObservationLeaseDeadline
    private var connection: NSXPCConnection?
    private var filterActive = false
    private var stopped = true
    private var generation = 0
    private var revision: UInt64 = 0
    private var demandActive = false
    private var demandChanged: @Sendable (ObservationDemand) -> Void = { _ in }
    private var leaseUntil: TimeInterval = 0
    private var deadline: (any ObservationLeaseDeadline)?

    public convenience init(listener: NSXPCListener, requiredClientCode: String) {
        self.init(listener: listener, requiredClientCode: requiredClientCode,
                  now: { ProcessInfo.processInfo.systemUptime }, makeDeadline: DispatchObservationDeadline.init)
    }

    init(listener: NSXPCListener, requiredClientCode: String,
         now: @escaping @Sendable () -> TimeInterval,
         makeDeadline: @escaping @Sendable (@escaping @Sendable () -> Void) -> any ObservationLeaseDeadline) {
        self.listener = listener; self.requiredClientCode = requiredClientCode
        self.now = now; self.makeDeadline = makeDeadline
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit { deadline?.cancel() }

    public var isFilterStopped: Bool {
        lock.lock(); defer { lock.unlock() }; return stopped
    }

    /// provider 开始监听需求后读一次快照，补齐 start 与第一个有效 read 交错的窗口。
    public var currentDemand: ObservationDemand {
        lock.lock(); defer { lock.unlock() }
        return ObservationDemand(generation: generation, revision: revision, isActive: demandActive)
    }

    @discardableResult public func startFilter(demandChanged: @escaping @Sendable (ObservationDemand) -> Void = { _ in }) -> Int {
        lock.lock()
        generation += 1; revision = 0; stopped = false; filterActive = true; demandActive = false
        self.demandChanged = demandChanged
        leaseUntil = 0; deadline?.cancel(); deadline = nil
        let previous = connection; connection = nil
        buffer.stop()
        let current = generation
        lock.unlock()
        previous?.invalidate()
        return current
    }

    public func beginStoppingFilter(generation expected: Int) {
        lock.lock()
        guard generation == expected else { lock.unlock(); return }
        filterActive = false
        let event = endLeaseLocked()
        buffer.stop()
        let callback = demandChanged
        lock.unlock()
        if let event { callback(event) }
    }

    public func finishStoppingFilter(generation expected: Int) {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else { return }
        stopped = true
    }

    private func endLeaseLocked() -> ObservationDemand? {
        leaseUntil = 0; deadline?.cancel(); deadline = nil
        buffer.endLease()
        guard demandActive else { return nil }
        demandActive = false; revision &+= 1
        return ObservationDemand(generation: generation, revision: revision, isActive: false)
    }

    private func expireLease(generation expected: Int) {
        lock.lock()
        // 已排队的旧截止回调或被续期的截止均不能撤销新的有效租约。
        guard generation == expected, demandActive, now() >= leaseUntil else { lock.unlock(); return }
        let event = endLeaseLocked()
        let callback = demandChanged
        lock.unlock()
        if let event { callback(event) }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection candidate: NSXPCConnection) -> Bool {
        candidate.setCodeSigningRequirement(requiredClientCode)
        candidate.exportedInterface = NSXPCInterface(with: NetworkObservationService.self)
        candidate.exportedObject = ObservationServiceSession(
            read: { [weak self] peer, first, cursor, epoch in
                guard let self else { return nil }
                self.lock.lock()
                guard self.filterActive, first || self.connection === peer else { self.lock.unlock(); return nil }
                let previous = first && self.connection !== peer ? self.connection : nil
                if first { self.connection = peer }
                let current = self.generation
                let instant = self.now()
                let batch = self.buffer.read(after: cursor, epoch: epoch, now: instant)
                self.leaseUntil = instant + ObservationLimits.leaseSeconds
                if self.deadline == nil {
                    self.deadline = self.makeDeadline { [weak self] in self?.expireLease(generation: current) }
                }
                self.deadline?.schedule(after: ObservationLimits.leaseSeconds)
                let event: ObservationDemand?
                if !self.demandActive {
                    self.demandActive = true; self.revision &+= 1
                    event = .init(generation: current, revision: self.revision, isActive: true)
                } else { event = nil }
                let callback = self.demandChanged
                self.lock.unlock()
                previous?.invalidate()
                if let event { callback(event) }
                return batch
            },
            diagnostics: { [weak self] window in self?.buffer.flowDiagnostics(windowSeconds: window) },
            stopped: { [weak self] in self?.isFilterStopped ?? false })
        candidate.invalidationHandler = { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            self.lock.lock()
            guard self.connection === candidate else { self.lock.unlock(); return }
            self.connection = nil
            let event = self.endLeaseLocked()
            let callback = self.demandChanged
            self.lock.unlock()
            if let event { callback(event) }
        }
        candidate.interruptionHandler = candidate.invalidationHandler
        candidate.resume()
        return true
    }
}

/// 无观察者时不创建源；活跃租约只有一个可重排的单次截止，没有常驻/周期定时器。
protocol ObservationLeaseDeadline: Sendable {
    func schedule(after seconds: TimeInterval)
    func cancel()
}
private final class DispatchObservationDeadline: ObservationLeaseDeadline, @unchecked Sendable {
    private let timer: any DispatchSourceTimer
    init(handler: @escaping @Sendable () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler(handler: handler)
        timer.resume()
    }
    func schedule(after seconds: TimeInterval) {
        timer.schedule(deadline: .now() + seconds, repeating: .never, leeway: .milliseconds(250))
    }
    func cancel() { timer.cancel() }
}

private final class ObservationServiceSession: NSObject, NetworkObservationService {
    private let lock = NSLock()
    private var hasRead = false
    private let read: (NSXPCConnection, Bool, Int64, String) -> ObservationBatch?
    private let diagnostics: (Double) -> FlowDiagnosticsDTO?
    private let stopped: () -> Bool

    init(read: @escaping (NSXPCConnection, Bool, Int64, String) -> ObservationBatch?,
         diagnostics: @escaping (Double) -> FlowDiagnosticsDTO?, stopped: @escaping () -> Bool) {
        self.read = read; self.diagnostics = diagnostics; self.stopped = stopped
    }

    func readEvents(after cursor: Int64, epoch: String, reply: @escaping (Data) -> Void) {
        guard epoch.utf8.count <= 36, cursor >= 0, let peer = NSXPCConnection.current() else { reply(Data()); return }
        lock.lock()
        let batch = read(peer, !hasRead, cursor, epoch)
        if batch != nil { hasRead = true }
        lock.unlock()
        guard let batch else { reply(Data()); return }
        reply((try? JSONEncoder().encode(batch)) ?? Data())
    }

    func flowDiagnostics(windowSeconds: Double, reply: @escaping @Sendable (Data) -> Void) {
        guard windowSeconds.isFinite, windowSeconds >= 0, NSXPCConnection.current() != nil,
              let snapshot = diagnostics(windowSeconds) else { reply(Data()); return }
        reply((try? JSONEncoder().encode(snapshot)) ?? Data())
    }

    func isFilterStopped(reply: @escaping @Sendable (Bool) -> Void) {
        guard NSXPCConnection.current() != nil else { reply(false); return }
        reply(stopped())
    }
}
