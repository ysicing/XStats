// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 生命周期查询与进程同寿命，过滤器停用后仍可查询；所有可变状态由同一把锁保护。
public final class ObservationServiceHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public let buffer = ObservationBuffer()
    private let lock = NSLock()
    private let listener: NSXPCListener
    private let requiredClientCode: String
    private var controlEndpoint: NSXPCListenerEndpoint?
    private var connection: NSXPCConnection?
    private var filterActive = false
    private var stopped = true
    private var generation = 0

    public init(listener: NSXPCListener, requiredClientCode: String) {
        self.listener = listener
        self.requiredClientCode = requiredClientCode
        super.init()
        listener.delegate = self
        listener.resume()
    }

    public var isFilterStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    @discardableResult public func startFilter() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        stopped = false
        filterActive = true
        buffer.stop()
        return generation
    }

    public func beginStoppingFilter(generation: Int) {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation else { return }
        filterActive = false
        buffer.stop()
    }

    public func finishStoppingFilter(generation: Int) {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation else { return }
        stopped = true
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection candidate: NSXPCConnection) -> Bool {
        // macOS 在每条消息上验证签名，未认证连接不能替换观察者或改变停止状态。
        candidate.setCodeSigningRequirement(requiredClientCode)
        candidate.exportedInterface = NSXPCInterface(with: NetworkObservationService.self)
        candidate.exportedObject = ObservationServiceSession(
            read: { [weak self] peer, first, cursor, epoch in
                guard let self else { return nil }
                self.lock.lock()
                guard self.filterActive, first || self.connection === peer else { self.lock.unlock(); return nil }
                let previous = first && self.connection !== peer ? self.connection : nil
                if first { self.connection = peer }
                // 成员校验和续租必须原子化，不能让失效会话在停止后重新续租。
                let batch = self.buffer.read(after: cursor, epoch: epoch)
                self.lock.unlock()
                previous?.invalidate()
                return batch
            },
            register: { [weak self] endpoint in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self.controlEndpoint = endpoint
            },
            endpoint: { [weak self] in
                guard let self else { return nil }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.controlEndpoint
            },
            stopped: { [weak self] peer in
                guard let self else { return false }
                self.lock.lock()
                let stopped = self.stopped
                self.lock.unlock()
                return stopped
            })
        candidate.invalidationHandler = { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.connection === candidate {
                self.connection = nil
                self.buffer.endLease()
            }
        }
        candidate.resume()
        return true
    }
}

private final class ObservationServiceSession: NSObject, NetworkObservationService {
    private let lock = NSLock()
    private var hasRead = false
    private let read: (NSXPCConnection, Bool, Int64, String) -> ObservationBatch?
    private let register: (NSXPCListenerEndpoint) -> Void
    private let endpoint: () -> NSXPCListenerEndpoint?
    private let stopped: (NSXPCConnection) -> Bool

    init(read: @escaping (NSXPCConnection, Bool, Int64, String) -> ObservationBatch?,
         register: @escaping (NSXPCListenerEndpoint) -> Void,
         endpoint: @escaping () -> NSXPCListenerEndpoint?,
         stopped: @escaping (NSXPCConnection) -> Bool) {
        self.read = read
        self.register = register
        self.endpoint = endpoint
        self.stopped = stopped
    }

    func readEvents(after cursor: Int64, epoch: String, reply: @escaping (Data) -> Void) {
        guard epoch.utf8.count <= 36, cursor >= 0, let peer = NSXPCConnection.current() else { reply(Data()); return }
        lock.lock(); let first = !hasRead; hasRead = true; lock.unlock()
        guard let batch = read(peer, first, cursor, epoch) else { reply(Data()); return }
        reply((try? JSONEncoder().encode(batch)) ?? Data())
    }

    func registerControlEndpoint(_ endpoint: NSXPCListenerEndpoint, reply: @escaping @Sendable () -> Void) {
        register(endpoint); reply()
    }

    func controlEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) { reply(endpoint()) }

    func isFilterStopped(reply: @escaping @Sendable (Bool) -> Void) {
        guard let peer = NSXPCConnection.current() else { reply(false); return }
        reply(stopped(peer))
    }
}
