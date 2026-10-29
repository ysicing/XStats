// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
import CaptureCore
@testable import CaptureUI

@Suite @MainActor struct ImageMosaicTests {
  private func image() throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
    return try #require(context.makeImage())
  }
  @Test func failedMosaicPreparationDoesNotBlockOrdinaryAnnotationsOrUndo() async throws {
    let model = ImageEditorModel(
      image: try image(),
      makeMosaics: { _ in
        throw CaptureError.captureFailed
      })
    let rectangle = ImageAnnotation(
      tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 60)])
    model.commit(rectangle)
    await model.waitForPendingWork()
    #expect(model.imageIsCurrent && model.error == nil && !model.rendering)
    let bitmap = NSBitmapImageRep(
      cgImage: try #require(model.image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    let border = try #require(bitmap.colorAt(x: 10, y: 30)?.usingColorSpace(.sRGB))
    #expect(border.greenComponent < 0.5)

    // 有遮挡时仍须失败关闭，不能导出未经遮挡的敏感信息。
    model.commit(
      ImageAnnotation(tool: .redact, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 50)]))
    await model.waitForPendingWork()
    #expect(!model.imageIsCurrent && model.error != nil && !model.rendering)
    model.undo()
    await model.waitForPendingWork()
    #expect(model.imageIsCurrent && model.error == nil)
  }

  @Test(arguments: [false, true])
  func savingRedactionsReusesPreparedMosaics(jpeg: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent(jpeg ? "image.jpg" : "image.png")
    let source = try #require(
      CGContext(
        data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    source.setFillColor(CGColor(gray: 1, alpha: 1))
    source.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
    source.setFillColor(CGColor(gray: 0, alpha: 1))
    for x in stride(from: 0, to: 160, by: 2) {
      source.fill(CGRect(x: x, y: 0, width: 1, height: 100))
    }
    let model = ImageEditorModel(
      image: try #require(source.makeImage()),
      saveImage: { document, url, jpeg, mosaics in
        let prepared = try #require(mosaics)
        try document.save(to: url, jpeg: jpeg, mosaics: prepared)
      })
    model.commit(
      ImageAnnotation(tool: .redact, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 50)]))
    await model.waitForPendingWork()
    model.save(to: destination, jpeg: jpeg)
    await model.waitForPendingWork()
    #expect(model.error == nil && !model.dirty && !model.rendering)
    let output = try #require(NSBitmapImageRep(data: Data(contentsOf: destination)))
    #expect(output.pixelsWide == 160 && output.pixelsHigh == 100)
    let color = try #require(output.colorAt(x: 40, y: 30)?.usingColorSpace(.sRGB))
    #expect(color.redComponent > 0.2 && color.redComponent < 0.8)
    #expect(abs(color.greenComponent - color.redComponent) < 0.05)
    #expect(abs(color.blueComponent - color.redComponent) < 0.05)
  }

  @Test func automaticMasksAreEditableAndUndoAsOneActionWithoutDuplicates() async throws {
    let model = ImageEditorModel(
      image: try image(),
      detectRegions: { _, _ in
        (
          [
            CGRect(x: 10, y: 20, width: 30, height: 10),
            CGRect(x: 80, y: 40, width: 40, height: 10),
          ],
          false
        )
      })
    model.detectSensitiveInformation()
    await model.waitForPendingWork()
    #expect(model.document.annotations.count == 2 && !model.detecting)
    #expect(model.document.annotations.allSatisfy { $0.tool == .redact })
    model.detectSensitiveInformation()
    await model.waitForPendingWork()
    #expect(model.document.annotations.count == 2)
    model.undo()
    await model.waitForPendingWork()
    #expect(model.document.annotations.isEmpty && !model.document.canUndo)
    #expect(model.detectedCount == nil)
    model.redo()
    await model.waitForPendingWork()
    let annotation = try #require(model.document.annotations.first)
    model.select(annotation.id)
    model.mosaicSize = .coarse
    model.applyStyle()
    await model.waitForPendingWork()
    #expect(model.selected?.mosaicSize == .coarse)
  }
  @Test func cancelledDetectionCannotPublishLateResultsOrStartAnOverlappingWorker() async throws {
    let (started, signal) = AsyncStream<Void>.makeStream()
    defer { signal.finish() }
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let model = ImageEditorModel(
      image: try image(),
      detectRegions: { _, _ in
        signal.yield(())
        guard release.wait(timeout: .now() + 10) == .success else {
          throw CaptureError.captureFailed
        }
        return ([CGRect(x: 10, y: 20, width: 30, height: 10)], false)
      })
    var iterator = started.makeAsyncIterator()
    model.detectSensitiveInformation()
    await iterator.next()
    model.cancelDetection()
    #expect(model.detecting, "Cancellation must keep recognition busy until the worker exits")
    model.detectSensitiveInformation()
    release.signal()
    await model.waitForPendingWork()
    #expect(model.document.annotations.isEmpty && !model.detecting && model.error == nil)
    model.detectSensitiveInformation()
    model.cancelPendingWork(terminating: true)
    release.signal()
    await model.waitForPendingWork()
    #expect(model.document.annotations.isEmpty && !model.rendering && !model.detecting)
  }
  @Test func fallbackRecognitionIsMarkedForReview() async throws {
    let model = ImageEditorModel(
      image: try image(),
      detectRegions: { _, _ in ([CGRect(x: 10, y: 20, width: 30, height: 10)], true) })
    model.detectSensitiveInformation()
    await model.waitForPendingWork()
    #expect(model.detectedCount == 1 && model.usedFastRecognition)
    #expect(model.document.annotations.count == 1)
  }
  @Test func cropIsPassedToRecognitionAndFailedRecognitionKeepsExistingWork() async throws {
    let crop = CGRect(x: 20, y: 30, width: 100, height: 50)
    let model = ImageEditorModel(
      image: try image(),
      detectRegions: { _, actual in
        #expect(actual == crop)
        throw CaptureError.captureFailed
      })
    try model.document.crop(to: crop)
    let annotation = ImageAnnotation(
      tool: .rectangle, points: [CGPoint(x: 30, y: 40), CGPoint(x: 50, y: 50)])
    model.document.add(annotation)
    model.detectSensitiveInformation()
    await model.waitForPendingWork()
    #expect(model.error != nil && model.document.annotations == [annotation])
    #expect(!model.rendering && !model.detecting)
  }
  @Test func croppedMosaicPreviewMatchesExportForEveryGranularity() async throws {
    let context = try #require(
      CGContext(
        data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for y in 0..<100 {
      for x in 0..<160 {
        context.setFillColor(
          CGColor(red: CGFloat(x) / 160, green: CGFloat(y) / 100, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
      }
    }
    for size in MosaicSize.allCases {
      let model = ImageEditorModel(image: try #require(context.makeImage()))
      await model.waitForPendingWork()
      try model.document.crop(to: CGRect(x: 20, y: 10, width: 100, height: 80))
      model.document.add(
        ImageAnnotation(
          tool: .redact, points: [CGPoint(x: 30, y: 20), CGPoint(x: 110, y: 85)], mosaicSize: size))
      let canvas = ImageCanvasView(model: model)
      canvas.frame = CGRect(x: 0, y: 0, width: 332, height: 272)
      // Cache-display bitmap reps may discard ICC profiles; use an explicit sRGB canvas surface.
      let surface = try #require(
        CGContext(
          data: nil, width: 332, height: 272, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      surface.translateBy(x: 0, y: 272)
      surface.scaleBy(x: 1, y: -1)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: surface, flipped: true)
      canvas.draw(canvas.bounds)
      NSGraphicsContext.restoreGraphicsState()
      let previewImage = try #require(surface.makeImage())
      let bitmap = NSBitmapImageRep(cgImage: previewImage)
      let preview = try #require(bitmap.colorAt(x: 166, y: 136)?.usingColorSpace(.sRGB))
      let output = NSBitmapImageRep(cgImage: try model.document.render())
      let exported = try #require(output.colorAt(x: 50, y: 40)?.usingColorSpace(.sRGB))
      #expect(abs(preview.redComponent - exported.redComponent) < 0.02)
      #expect(abs(preview.greenComponent - exported.greenComponent) < 0.02)
      #expect(abs(preview.blueComponent - exported.blueComponent) < 0.02)
    }
  }

}
