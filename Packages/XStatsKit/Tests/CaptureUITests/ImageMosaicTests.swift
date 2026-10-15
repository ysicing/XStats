// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
import CaptureCore
@testable import CaptureUI

@Suite @MainActor struct ImageMosaicTests {
    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        return try #require(context.makeImage())
    }
    @Test func automaticMasksAreEditableAndUndoAsOneActionWithoutDuplicates() async throws {
        let model = ImageEditorModel(image: try image(), detectRegions: { _, _ in
            [CGRect(x: 10, y: 20, width: 30, height: 10), CGRect(x: 80, y: 40, width: 40, height: 10)]
        })
        model.detectSensitiveInformation()
        await model.waitForPendingWork()
        #expect(model.document.annotations.count == 2 && !model.detecting)
        #expect(model.document.annotations.allSatisfy { $0.tool == .redact })
        model.detectSensitiveInformation(); await model.waitForPendingWork()
        #expect(model.document.annotations.count == 2)
        model.undo(); await model.waitForPendingWork()
        #expect(model.document.annotations.isEmpty && !model.document.canUndo)
        #expect(model.detectedCount == nil)
        model.redo(); await model.waitForPendingWork()
        let annotation = try #require(model.document.annotations.first)
        model.select(annotation.id); model.mosaicSize = .coarse; model.applyStyle()
        await model.waitForPendingWork()
        #expect(model.selected?.mosaicSize == .coarse)
    }
    @Test func cancelledDetectionCannotPublishLateResultsOrStartAnOverlappingWorker() async throws {
        let (started, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = ImageEditorModel(image: try image(), detectRegions: { _, _ in
            signal.yield(())
            guard release.wait(timeout: .now() + 10) == .success else { throw CaptureError.captureFailed }
            return [CGRect(x: 10, y: 20, width: 30, height: 10)]
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
        model.detectSensitiveInformation(); model.cancelPendingWork(terminating: true)
        release.signal()
        await model.waitForPendingWork()
        #expect(model.document.annotations.isEmpty && !model.rendering && !model.detecting)
    }
    @Test func cropIsPassedToRecognitionAndFailedRecognitionKeepsExistingWork() async throws {
        let crop = CGRect(x: 20, y: 30, width: 100, height: 50)
        let model = ImageEditorModel(image: try image(), detectRegions: { _, actual in
            #expect(actual == crop)
            throw CaptureError.captureFailed
        })
        try model.document.crop(to: crop)
        let annotation = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 30, y: 40), CGPoint(x: 50, y: 50)])
        model.document.add(annotation)
        model.detectSensitiveInformation(); await model.waitForPendingWork()
        #expect(model.error != nil && model.document.annotations == [annotation])
        #expect(!model.rendering && !model.detecting)
    }
    @Test func croppedMosaicPreviewMatchesExportForEveryGranularity() async throws {
        let context = try #require(CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<100 {
            for x in 0..<160 {
                context.setFillColor(CGColor(red: CGFloat(x) / 160, green: CGFloat(y) / 100, blue: 0.5, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        for size in MosaicSize.allCases {
            let model = ImageEditorModel(image: try #require(context.makeImage()))
            await model.waitForPendingWork()
            try model.document.crop(to: CGRect(x: 20, y: 10, width: 100, height: 80))
            model.document.add(ImageAnnotation(tool: .redact, points: [CGPoint(x: 30, y: 20), CGPoint(x: 110, y: 85)], mosaicSize: size))
            let canvas = ImageCanvasView(model: model)
            canvas.frame = CGRect(x: 0, y: 0, width: 332, height: 272)
            // Cache-display bitmap reps may discard ICC profiles; use an explicit sRGB canvas surface.
            let surface = try #require(CGContext(data: nil, width: 332, height: 272, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            surface.translateBy(x: 0, y: 272); surface.scaleBy(x: 1, y: -1)
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
