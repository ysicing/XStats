// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 系统回调可能晚于取消到达；锁内只交换状态，锁外恢复且只恢复一次。
final class CaptureCallback<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var registering = false
    private var pendingCancellation: (@Sendable () -> Void)?
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .failure(is CancellationError) = result { return true }
        return false
    }
    private func reserveStart(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        lock.lock()
        let result = result
        if result == nil { self.continuation = continuation; registering = true }
        lock.unlock()
        if let result { continuation.resume(with: result) }
        return result == nil
    }
    private func didRegister() {
        lock.lock()
        registering = false
        let cleanup = pendingCancellation; pendingCancellation = nil
        lock.unlock()
        cleanup?()
    }
    private func cancel(_ cleanup: @escaping @Sendable () -> Void) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .failure(CancellationError())
        let continuation = continuation; self.continuation = nil
        let deferCleanup = registering
        if deferCleanup { pendingCancellation = cleanup }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        if !deferCleanup { cleanup() }
    }
    @discardableResult func finish(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
    func wait(onCancel: @escaping @Sendable () -> Void = {},
              start: @Sendable (CaptureCallback<Value>) -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // 与取消原子竞争启动资格。注册中的取消先释放等待者，再在注册返回后停止，
                // 避免 stop 先执行、start 后执行；不能持锁调用可能同步完成的系统回调。
                if reserveStart(continuation) {
                    start(self)
                    didRegister()
                }
            }
        } onCancel: {
            self.cancel(onCancel)
        }
    }
}
