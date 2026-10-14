// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
import CoreGraphics
@testable import CaptureCore

@Suite struct ImageEditingTests {
    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return try #require(context.makeImage())
    }
    @Test func redactionIsBakedIntoRenderedPixelsAndCanBeUndone() throws {
        var document = ImageEditDocument(image: try image())
        document.add(ImageAnnotation(tool: .redact, points: [CGPoint(x: 5, y: 5), CGPoint(x: 15, y: 15)]))
        let rendered = try document.render()
        let bytes = try #require(rendered.dataProvider?.data) as Data
        let offset = 10 * rendered.bytesPerRow + 10 * 4
        #expect(bytes[offset] == 0)
        #expect(bytes[offset + 1] == 0)
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
