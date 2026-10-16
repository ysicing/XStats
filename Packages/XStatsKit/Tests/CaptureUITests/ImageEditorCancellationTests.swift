// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
import CaptureCore
@testable import CaptureUI

@Suite @MainActor struct ImageEditorCancellationTests {
  @Test(.timeLimit(.minutes(1))) func terminationWaitsForCurrentAndPreviouslyCancelledSaves()
    async throws
  {
    let context = try #require(
      CGContext(
        data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.png")
    let second = directory.appendingPathComponent("second.png")
    let original = Data([1, 2, 3])
    try original.write(to: first)
    try original.write(to: second)
    let firstRelease = DispatchSemaphore(value: 0)
    let secondRelease = DispatchSemaphore(value: 0)
    defer {
      firstRelease.signal()
      secondRelease.signal()
    }
    let (started, starts) = AsyncStream<URL>.makeStream()
    let (finished, finishes) = AsyncStream<URL>.makeStream()
    defer {
      starts.finish()
      finishes.finish()
    }
    let model = ImageEditorModel(image: try #require(context.makeImage())) { document, url, jpeg in
      let staging = url.appendingPathExtension("staging")
      try original.write(to: staging)
      defer {
        try? FileManager.default.removeItem(at: staging)
        finishes.yield(url)
      }
      starts.yield(url)
      // 模拟编码器尚未响应取消；工作线程等待有上限，主线程保持可用。
      let release = url == first ? firstRelease : secondRelease
      guard release.wait(timeout: .now() + 10) == .success else { throw CaptureError.exportFailed }
      try Task.checkCancellation()
      try document.save(to: url, jpeg: jpeg)
    }
    var startIterator = started.makeAsyncIterator()
    var finishIterator = finished.makeAsyncIterator()
    model.save(to: first, jpeg: false)
    #expect(await startIterator.next() == first)
    model.cancelPendingWork()
    model.save(to: second, jpeg: false)
    #expect(await startIterator.next() == second)
    model.cancelPendingWork(terminating: true)
    let (waiting, waitSignal) = AsyncStream<Void>.makeStream()
    var completed = false
    let waiter = Task {
      waitSignal.yield(())
      waitSignal.finish()
      await model.waitForPendingWork()
      completed = true
    }
    for await _ in waiting { break }
    #expect(!completed)
    secondRelease.signal()
    #expect(await finishIterator.next() == second)
    #expect(!completed, "旧的已取消任务仍未收尾，不能确认退出")
    firstRelease.signal()
    await waiter.value
    #expect(completed && model.terminating && model.dirty && !model.rendering)
    #expect(try Data(contentsOf: first) == original)
    #expect(try Data(contentsOf: second) == original)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [
        "first.png", "second.png",
      ])
    model.save(to: directory.appendingPathComponent("after-termination.png"), jpeg: false)
    await model.waitForPendingWork()
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("after-termination.png").path))
  }
}
