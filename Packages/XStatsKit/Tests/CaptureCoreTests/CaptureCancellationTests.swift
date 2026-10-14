// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
import os
@testable import CaptureCore

@Suite struct CaptureCancellationTests {
    @Test func cancelledBeforeStartingDoesNotLaunchNativeWork() async {
        let starts = OSAllocatedUnfairLock(initialState: 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CaptureCallback<Int>().wait { _ in starts.withLock { $0 += 1 } }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(starts.withLock { $0 } == 0)
    }
    @Test(.timeLimit(.minutes(1))) func cancellationReleasesWaiterWithoutNativeCompletion() async {
        let callback = CaptureCallback<Int>()
        let cleanups = OSAllocatedUnfairLock(initialState: 0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await callback.wait(onCancel: { cleanups.withLock { $0 += 1 } }) { _ in signal.yield(()); signal.finish() }
        }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cleanups.withLock { $0 } == 1)
        // 原生回调即使迟到、重复到达，也不能恢复已取消的任务。
        #expect(!callback.finish(.success(42)))
        #expect(!callback.finish(.failure(CaptureError.captureFailed)))
        #expect(callback.isCancelled)
    }
    @Test func nativeFailureAndSuccessRemainDistinctFromCancellation() async throws {
        let value = try await CaptureCallback<Int>().wait { $0.finish(.success(42)) }
        #expect(value == 42)
        await #expect(throws: CaptureError.captureFailed) {
            try await CaptureCallback<Int>().wait { $0.finish(.failure(CaptureError.captureFailed)) }
        }
    }
    @Test @MainActor func discardReleasesTemporaryMediaAndAllowsNewRecorder() async throws {
        for _ in 0..<2 {
            let media = try RecordingMedia()
            let recorder = ScreenRecorder(media: media)
            try Data([1, 2, 3]).write(to: media.newSegmentURL())
            try await recorder.discard()
            #expect(!FileManager.default.fileExists(atPath: media.directory.path))
        }
    }
}
