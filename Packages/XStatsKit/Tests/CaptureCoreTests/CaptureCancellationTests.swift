// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
import os
import ScreenCaptureKit
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
      try await callback.wait(onCancel: { cleanups.withLock { $0 += 1 } }) { _ in
        signal.yield(())
        signal.finish()
      }
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
  @Test(.timeLimit(.minutes(1))) func cancellationStopsOnlyAfterNativeRegistration() async {
    let callback = CaptureCallback<Int>()
    let events = OSAllocatedUnfairLock(initialState: [String]())
    let task = Task {
      try await callback.wait(onCancel: { events.withLock { $0.append("stop") } }) { _ in
        // 在同步注册返回前取消，直接核对清理顺序，不阻塞协作线程等待其他任务。
        withUnsafeCurrentTask { $0?.cancel() }
        #expect(callback.isCancelled)
        #expect(events.withLock { $0.isEmpty })
        events.withLock { $0.append("start") }
      }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(events.withLock { $0 } == ["start", "stop"])
  }
  @Test @MainActor func discardReleasesTemporaryMediaAndAllowsNewRecorder() async throws {
    for _ in 0..<2 {
      let media = try RecordingMedia(root: FileManager.default.temporaryDirectory)
      let recorder = ScreenRecorder(media: media)
      try Data([1, 2, 3]).write(to: media.newSegmentURL())
      try await recorder.discard()
      #expect(!FileManager.default.fileExists(atPath: media.directory.path))
    }
  }
  @Test @MainActor func failedStopRetainsProducerForTheNextStopAttempt() async throws {
    let media = try RecordingMedia(root: FileManager.default.temporaryDirectory)
    defer { try? FileManager.default.removeItem(at: media.directory) }
    // 构造流但不启动采集，测试不需要屏幕权限。
    let stream = SCStream(
      filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
    var attempts = 0
    let recorder = ScreenRecorder(media: media, stream: stream) { _ in
      attempts += 1
      if attempts == 1 { throw CaptureError.captureFailed }
    }
    await #expect(throws: CaptureError.captureFailed) { try await recorder.stop() }
    #expect(recorder.isCapturing)
    try await recorder.stop()
    #expect(!recorder.isCapturing)
    #expect(attempts == 2)
    try await recorder.stop()
    #expect(attempts == 2)
  }
  @Test(arguments: [SCStreamError.Code.userDeclined, .internalError])
  @MainActor func streamDelegatePreservesPermissionAndCaptureFailure(code: SCStreamError.Code)
    async throws
  {
    let media = try RecordingMedia(root: FileManager.default.temporaryDirectory)
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let stream = SCStream(
      filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
    let recorder = ScreenRecorder(media: media, stream: stream) { _ in }
    let (failures, continuation) = AsyncStream<CaptureError>.makeStream()
    recorder.onFailure = { continuation.yield($0) }
    var iterator = failures.makeAsyncIterator()
    recorder.stream(
      stream, didStopWithError: NSError(domain: SCStreamErrorDomain, code: code.rawValue))
    #expect(await iterator.next() == (code == .userDeclined ? .screenPermission : .captureFailed))
    #expect(!recorder.isCapturing)
    try await recorder.stop()
    recorder.stream(
      stream,
      didStopWithError: NSError(
        domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
    continuation.finish()
    #expect(await iterator.next() == nil, "已停止的流的迟到回调不能恢复错误状态")
  }
}
