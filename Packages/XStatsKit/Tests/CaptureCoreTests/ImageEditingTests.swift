// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import CaptureCore

@Suite struct ImageEditingTests {
    @Test func mosaicUsesSourceColorsInsteadOfSolidBlack() throws {
        let original = try mosaicFixture()
        var document = ImageEditDocument(image: original)
        document.add(ImageAnnotation(tool: .redact, points: [CGPoint(x: 10, y: 5), CGPoint(x: 70, y: 35)]))
        let result = NSBitmapImageRep(cgImage: try document.render())
        let a = try #require(result.colorAt(x: 30, y: 20)?.usingColorSpace(.deviceRGB))
        let b = try #require(result.colorAt(x: 31, y: 20)?.usingColorSpace(.deviceRGB))
        #expect(a.greenComponent > 0.4 && a.blueComponent > 0.7)
        #expect(abs(a.redComponent - b.redComponent) < 0.001)
        document.undo()
        let clean = NSBitmapImageRep(cgImage: try document.render())
        #expect(clean.colorAt(x: 30, y: 20) != clean.colorAt(x: 31, y: 20))
    }
    @Test func objectEditsAndDeletionRestoreIdentityAndStyleThroughHistory() throws {
        var document = ImageEditDocument(image: try image())
        let original = ImageAnnotation(tool: .text, points: [CGPoint(x: 4, y: 5)], text: "Before")
        document.add(original)
        var edited = original.translated(by: CGSize(width: 8, height: 6))
        edited.text = "After"; edited.fontSize = 40
        document.update(edited)
        document.remove(id: original.id)
        #expect(document.annotations.isEmpty)
        document.undo()
        #expect(document.annotations == [edited])
        document.undo()
        #expect(document.annotations == [original])
        document.redo()
        #expect(document.annotations == [edited])
        document.redo()
        #expect(document.annotations.isEmpty)
    }
    @Test func hitTestingUsesVisibleShapesAndTopmostObject() throws {
        var document = ImageEditDocument(image: try image())
        let line = ImageAnnotation(tool: .arrow, points: [CGPoint(x: 2, y: 2), CGPoint(x: 25, y: 20)])
        let cover = ImageAnnotation(tool: .redact, points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)])
        document.add(line); document.add(cover)
        #expect(document.annotation(at: CGPoint(x: 15, y: 15), tolerance: 2)?.id == cover.id)
        #expect(line.contains(CGPoint(x: 3, y: 20), tolerance: 2) == false)
        #expect(line.contains(CGPoint(x: 12, y: 10), tolerance: 2))
        #expect(document.annotation(at: CGPoint(x: 35, y: 25), tolerance: 2) == nil)
    }
    @Test func movingRedactionChangesFinalPixelsAndDeletionRestoresThem() throws {
        let source = try mosaicFixture()
        var document = ImageEditDocument(image: source)
        let cover = ImageAnnotation(tool: .redact, points: [CGPoint(x: 2, y: 2), CGPoint(x: 8, y: 8)])
        document.add(cover)
        document.update(cover.translated(by: CGSize(width: 20, height: 10)))
        let output = try document.render()
        let bytes = try #require(output.dataProvider?.data) as Data
        let original = try #require(source.dataProvider?.data) as Data
        #expect(bytes[4 * output.bytesPerRow + 4 * 4] == original[4 * source.bytesPerRow + 4 * 4])
        #expect(bytes[14 * output.bytesPerRow + 24 * 4] != original[14 * source.bytesPerRow + 24 * 4])
        document.remove(id: cover.id)
        let clean = try document.render()
        let restored = try #require(clean.dataProvider?.data) as Data
        #expect(restored[14 * clean.bytesPerRow + 24 * 4] == original[14 * source.bytesPerRow + 24 * 4])
    }
    @Test func resizingPenPreservesItsShapeAndIdentity() {
        let pen = ImageAnnotation(tool: .pen, points: [CGPoint(x: 10, y: 10), CGPoint(x: 15, y: 20), CGPoint(x: 20, y: 10)])
        let resized = pen.resized(to: CGRect(x: 20, y: 30, width: 20, height: 30))
        #expect(resized.id == pen.id)
        #expect(resized.points == [CGPoint(x: 20, y: 30), CGPoint(x: 30, y: 60), CGPoint(x: 40, y: 30)])
    }
    @Test func noOpAndMissingObjectEditsDoNotConsumeUndo() throws {
        var document = ImageEditDocument(image: try image())
        let item = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 3, y: 3), CGPoint(x: 20, y: 20)])
        document.add(item)
        document.update(item)
        document.remove(id: UUID())
        document.undo()
        #expect(document.annotations.isEmpty && !document.canUndo)
        document.add(item)
        #expect(!document.canRedo)
    }
    private func mosaicFixture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<80 {
            context.setFillColor(CGColor(red: CGFloat(x) / 80, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 40))
        }
        return try #require(context.makeImage())
    }
    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return try #require(context.makeImage())
    }
    @Test func redactionIsBakedIntoRenderedPixelsAndCanBeUndone() throws {
        let source = try mosaicFixture()
        var document = ImageEditDocument(image: source)
        document.add(ImageAnnotation(tool: .redact, points: [CGPoint(x: 5, y: 5), CGPoint(x: 15, y: 15)]))
        let rendered = try document.render()
        let bytes = try #require(rendered.dataProvider?.data) as Data
        let offset = 10 * rendered.bytesPerRow + 10 * 4
        let original = try #require(source.dataProvider?.data) as Data
        #expect(bytes[offset] != original[10 * source.bytesPerRow + 10 * 4])
        #expect(bytes[offset + 1] > 100)
        document.undo()
        #expect(document.annotations.isEmpty)
        document.redo()
        #expect(document.annotations.count == 1)
    }
    @Test func cropAndHistoryKeepTheOriginalImage() throws {
        var document = ImageEditDocument(image: try image())
        try document.crop(to: CGRect(x: 10, y: 5, width: 20, height: 15))
        #expect(try document.render().width == 20)
        #expect(try document.render().height == 15)
        #expect(document.original.width == 40)
        document.undo()
        #expect(try document.render().width == 40)
        #expect(throws: CaptureError.self) { try document.crop(to: CGRect(x: 100, y: 100, width: 3, height: 3)) }
    }
    @Test func undoHistoryHasAFixedBound() throws {
        var document = ImageEditDocument(image: try image())
        for i in 0..<150 { document.add(ImageAnnotation(tool: .rectangle, points: [CGPoint(x: i % 20, y: 1), CGPoint(x: 25, y: 25)])) }
        var undoCount = 0
        while document.canUndo { document.undo(); undoCount += 1 }
        #expect(undoCount == 100)
    }
    @Test func cancelledImageSavePreservesExistingDestination() async throws {
        let document = ImageEditDocument(image: try image())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("image.png")
        let sentinel = Data("keep existing image".utf8)
        try sentinel.write(to: output)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try document.save(to: output)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: output) == sentinel)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["image.png"])
        try document.save(to: output)
        #expect(try Data(contentsOf: output).prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }
}
