// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
import CaptureCore
@testable import CaptureUI

@Suite @MainActor struct ImageCanvasInteractionTests {
    private func editor() throws -> (ImageEditorModel, ImageCanvasView, NSWindow) {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let model = ImageEditorModel(image: try #require(context.makeImage()))
        let canvas = ImageCanvasView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        return (model, canvas, window)
    }
    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in canvas: ImageCanvasView) throws -> NSEvent {
        let rect = canvas.imageRect, crop = canvas.model.document.cropRect
        let location = canvas.convert(CGPoint(x: rect.minX + (point.x - crop.minX) * rect.width / crop.width,
            y: rect.minY + (point.y - crop.minY) * rect.height / crop.height), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func expectBounds(_ actual: CGRect?, _ expected: CGRect) {
        #expect(abs((actual?.minX ?? .infinity) - expected.minX) < 0.001)
        #expect(abs((actual?.minY ?? .infinity) - expected.minY) < 0.001)
        #expect(abs((actual?.width ?? .infinity) - expected.width) < 0.001)
        #expect(abs((actual?.height ?? .infinity) - expected.height) < 0.001)
    }
    @Test func dragPreviewUsesSourceColorsAndDoesNotCommitUntilMouseUp() async throws {
        let (model, canvas, window) = try editor()
        defer { window.orderOut(nil) }
        await model.waitForPendingWork()
        model.tool = .redact; canvas.synchronize()
        canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 20, y: 20), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 60, y: 60), in: canvas))
        #expect(model.document.annotations.isEmpty && !model.document.canUndo)
        let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let rect = canvas.imageRect
        let inside = try #require(bitmap.colorAt(x: Int(rect.minX + rect.width * 0.4), y: Int(rect.minY + rect.height * 0.4))?.usingColorSpace(.deviceRGB))
        #expect(inside.redComponent > 0.99 && inside.greenComponent > 0.99 && inside.blueComponent > 0.99)
        canvas.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 60, y: 60), in: canvas))
        await model.waitForPendingWork()
        #expect(model.document.annotations.count == 1 && model.selectedID == model.document.annotations[0].id)
        model.undo(); await model.waitForPendingWork()
        #expect(model.document.annotations.isEmpty && !model.document.canUndo)
    }
    @Test func selectionMovesAndResizesAsSingleUndoSteps() async throws {
        let (model, canvas, window) = try editor()
        defer { window.orderOut(nil) }
        let item = ImageAnnotation(tool: .redact, points: [CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 40)])
        model.document.add(item)
        canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 30, y: 30), in: canvas))
        for x in 31...45 { canvas.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: x, y: 40), in: canvas)) }
        #expect(model.document.annotations[0] == item)
        canvas.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 45, y: 40), in: canvas))
        await model.waitForPendingWork()
        expectBounds(model.selected?.bounds, CGRect(x: 35, y: 30, width: 20, height: 20))
        canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 55, y: 50), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 80, y: 70), in: canvas))
        await model.waitForPendingWork()
        expectBounds(model.selected?.bounds, CGRect(x: 35, y: 30, width: 45, height: 40))
        model.undo(); await model.waitForPendingWork()
        expectBounds(model.document.annotations[0].bounds, CGRect(x: 35, y: 30, width: 20, height: 20))
        model.undo(); await model.waitForPendingWork()
        #expect(model.document.annotations[0] == item)
    }
    @Test func inlineTextCommitsAndCanBeEditedWithoutCreatingADuplicate() async throws {
        let (model, canvas, window) = try editor()
        defer { window.orderOut(nil) }
        model.tool = .text; canvas.synchronize()
        canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 20, y: 20), in: canvas))
        let field = try #require(canvas.subviews.first as? NSTextField)
        field.stringValue = "Before"; model.finishEditing()
        await model.waitForPendingWork()
        let id = try #require(model.selectedID)
        model.tool = .text; canvas.synchronize()
        canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 23, y: 23), in: canvas))
        let editing = try #require(canvas.subviews.first as? NSTextField)
        editing.stringValue = "After"
        model.color = .systemBlue; model.fontSize = 40; model.applyStyle(); canvas.synchronize()
        #expect(!model.rendering && canvas.subviews.first === editing)
        model.finishEditing()
        await model.waitForPendingWork()
        #expect(model.document.annotations.count == 1 && model.selectedID == id && model.selected?.text == "After")
        #expect(model.selected?.fontSize == 40 && model.selected?.color == NSColor.systemBlue.cgColor)
        model.undo(); await model.waitForPendingWork()
        #expect(model.document.annotations[0].text == "Before")
    }
    @Test(arguments: [false, true]) func savedTextStyleDraftRequiresUnsavedConfirmation(changeFont: Bool) async throws {
        let (model, canvas, window) = try editor()
        defer { window.close() }
        let item = ImageAnnotation(tool: .text, points: [CGPoint(x: 20, y: 20)], text: "Saved text")
        model.document.add(item); model.select(item.id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        model.save(to: file, jpeg: false)
        await model.waitForPendingWork()
        #expect(!model.dirty)
        model.tool = .text; canvas.synchronize()
        canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 23, y: 23), in: canvas))
        #expect(model.editingText)
        model.applyStyle()
        #expect(!model.dirty, "Selecting the existing style must not create an unsaved draft")
        if changeFont { model.fontSize = 40 } else { model.color = .systemBlue }
        model.applyStyle(); canvas.synchronize()
        #expect(model.dirty, "Quit protection must see style-only edits before inline text commits")
        #expect(!model.rendering && model.document.annotations[0] == item)
        model.finishEditing()
        await model.waitForPendingWork()
        #expect(model.selected?.text == "Saved text")
        if changeFont { #expect(model.selected?.fontSize == 40) }
        else { #expect(model.selected?.color == NSColor.systemBlue.cgColor) }
        model.save(to: file, jpeg: false)
        await model.waitForPendingWork()
        #expect(!model.dirty && FileManager.default.fileExists(atPath: file.path))
        model.undo(); await model.waitForPendingWork()
        #expect(model.dirty && model.document.annotations[0] == item)
    }
    @Test func selectedOutlineCanMoveFromItsInteriorAndClippedObjectsDoNotJump() async throws {
        let (model, canvas, window) = try editor()
        defer { window.orderOut(nil) }
        let item = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 80)])
        model.document.add(item); model.select(item.id)
        canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 50, y: 50), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 60, y: 60), in: canvas))
        await model.waitForPendingWork()
        expectBounds(model.selected?.bounds, CGRect(x: 30, y: 30, width: 60, height: 60))
        try model.document.crop(to: CGRect(x: 40, y: 40, width: 50, height: 50))
        let before = try #require(model.selected)
        canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 60, y: 60), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 60, y: 60), in: canvas))
        await model.waitForPendingWork()
        #expect(model.selected == before)
    }
    @Test func croppedCanvasMatchesExportOrientation() throws {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
        let model = ImageEditorModel(image: try #require(context.makeImage()))
        try model.document.crop(to: CGRect(x: 10, y: 10, width: 80, height: 30))
        let canvas = ImageCanvasView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let preview = try #require(bitmap.colorAt(x: Int(canvas.imageRect.midX), y: Int(canvas.imageRect.midY))?.usingColorSpace(.deviceRGB))
        let export = try #require(NSBitmapImageRep(cgImage: model.document.render()).colorAt(x: 40, y: 15)?.usingColorSpace(.deviceRGB))
        #expect(abs(preview.redComponent - export.redComponent) < 0.01)
        #expect(abs(preview.blueComponent - export.blueComponent) < 0.01)
    }
}
