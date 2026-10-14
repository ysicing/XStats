// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 系统回调可能晚于取消到达；锁内只交换状态，锁外恢复且只恢复一次。
final class CaptureCallback<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .failure(is CancellationError) = result { return true }
        return false
    }
    private func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        let result = result
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
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
                install(continuation)
                if !isCancelled { start(self) }
            }
        } onCancel: {
            if self.finish(.failure(CancellationError())) { onCancel() }
        }
    }
}
