// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 带代次和单调序号的需求边沿；跨锁发布时乱序到达也不能撤销更新的读取租约。
public struct ObservationDemand: Sendable {
    public let generation: Int
    public let revision: UInt64
    public let isActive: Bool
    public init(generation: Int, revision: UInt64, isActive: Bool) {
        self.generation = generation; self.revision = revision; self.isActive = isActive
    }
}

/// 同一实例最多一个 apply 在途；锁只保护状态，SDK 调用及外部回调始终在锁外。
/// start/stop 换代不会与旧 apply 并行；旧完成仅更新实际已应用值，再收敛到最新需求。
public final class FilterSettingsLifecycle: @unchecked Sendable {
    public typealias Completion = @Sendable ((any Error)?) -> Void
    public typealias Apply = @Sendable (Bool, @escaping Completion) -> Void
    private struct Request {
        let id: UInt64
        let generation: Int
        let revision: UInt64
        let observing: Bool
        let initial: Bool
    }
    private let lock = NSLock()
    private let apply: Apply
    private let onError: @Sendable (Int, Bool, any Error) -> Void
    private let onResult: @Sendable (Int, UInt64, Bool, (any Error)?) -> Void
    private var generation = 0
    private var revision: UInt64 = 0
    private var requestID: UInt64 = 0
    private var running = false
    private var desired = false
    private var initialRequired = false
    private var applied: Bool?
    private var inFlight: Request?
    private var failed: Request?
    private var startCompletion: Completion?
    private var stopCompletions: [@Sendable () -> Void] = []

    public init(apply: @escaping Apply, onError: @escaping @Sendable (Int, Bool, any Error) -> Void = { _, _, _ in },
                onResult: @escaping @Sendable (Int, UInt64, Bool, (any Error)?) -> Void = { _, _, _, _ in }) {
        self.apply = apply
        self.onError = onError
        self.onResult = onResult
    }

    /// 最后成功应用的系统设置；apply 失败不能伪报 allow 已生效。
    public var appliedObservation: Bool? {
        lock.lock(); defer { lock.unlock() }; return applied
    }

    public func start(generation next: Int, completion: @escaping Completion) {
        lock.lock()
        guard next > generation else { lock.unlock(); completion(CancellationError()); return }
        let previousStart = startCompletion
        let previousStops = stopCompletions
        stopCompletions.removeAll()
        generation = next; revision = 0; running = true; desired = false
        initialRequired = true; failed = nil; startCompletion = completion
        let request = nextRequestLocked()
        lock.unlock()
        previousStart?(CancellationError())
        previousStops.forEach { $0() }
        execute(request)
    }

    public func setDemand(_ demand: ObservationDemand) {
        lock.lock()
        guard running, demand.generation == generation, demand.revision > revision else { lock.unlock(); return }
        revision = demand.revision; desired = demand.isActive
        let request = nextRequestLocked()
        lock.unlock()
        execute(request)
    }

    /// 停止完成等待在途设置收尾及最后一次 allow；过期代次不得影响新 provider。
    public func stop(generation expected: Int, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        guard generation > 0, expected == generation else { lock.unlock(); completion(); return }
        running = false; desired = false; revision &+= 1
        stopCompletions.append(completion)
        let starting = startCompletion
        startCompletion = nil
        let request = nextRequestLocked()
        let stops = takeStopCompletionsLocked()
        lock.unlock()
        starting?(CancellationError())
        stops.forEach { $0() }
        execute(request)
    }

    private func nextRequestLocked() -> Request? {
        guard inFlight == nil else { return nil }
        let mode = initialRequired ? false : desired
        guard initialRequired || applied != mode else { return nil }
        // 同一需求失败后不忙等或后台重试；新读取/停止需求才能触发下一次尝试。
        if let failed, failed.generation == generation, failed.revision == revision, failed.observing == mode { return nil }
        requestID &+= 1
        let request = Request(id: requestID, generation: generation, revision: revision,
                              observing: mode, initial: initialRequired)
        initialRequired = false
        inFlight = request
        return request
    }

    private func execute(_ request: Request?) {
        guard let request else { return }
        apply(request.observing) { [weak self] error in self?.finish(request, error: error) }
    }

    private func finish(_ request: Request, error: (any Error)?) {
        lock.lock()
        guard inFlight?.id == request.id else { lock.unlock(); return }
        inFlight = nil
        if error == nil { applied = request.observing }
        let current = request.generation == generation
        var starting: Completion?
        if current && request.initial {
            starting = startCompletion; startCompletion = nil
            if error != nil { running = false; desired = false }
        }
        if current && error != nil {
            // 初始 allow 失败终止整个启动请求，提前到达的 read 不能变成隐式重试。
            failed = Request(id: request.id, generation: generation,
                             revision: request.initial ? revision : request.revision,
                             observing: request.observing, initial: request.initial)
        }
        let next = nextRequestLocked()
        let stops = takeStopCompletionsLocked()
        lock.unlock()
        if current { onResult(request.generation, request.id, request.observing, error) }
        starting?(error)
        if current, let error { onError(request.generation, request.observing, error) }
        stops.forEach { $0() }
        execute(next)
    }

    private func takeStopCompletionsLocked() -> [@Sendable () -> Void] {
        guard !running, inFlight == nil else { return [] }
        let completions = stopCompletions
        stopCompletions.removeAll()
        return completions
    }
}
