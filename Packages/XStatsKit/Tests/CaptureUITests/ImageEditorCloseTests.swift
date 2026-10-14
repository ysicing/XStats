// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
@testable import CaptureUI

@Suite(.serialized) @MainActor struct ImageEditorCloseTests {
    private func editor() throws -> (ImageEditorWindow, ImageCanvasView, NSWindow) {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let controller = ImageEditorWindow(image: try #require(context.makeImage()))
        let window = try #require(controller.window)
        let canvas = ImageCanvasView(model: controller.model)
        window.contentView = canvas; canvas.frame = CGRect(x: 0, y: 0, width: 950, height: 680)
        // Native window animations can end Swift's async test entry-point run loop prematurely.
        // Keep the real window/sheet flow, but disable animation in this fixture only.
        window.animationBehavior = .none
        controller.model.tool = .text; canvas.synchronize()
        let rect = canvas.imageRect
        let point = canvas.convert(CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.2), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let field = try #require(canvas.subviews.first as? NSTextField)
        field.stringValue = "Uncommitted text"
        return (controller, canvas, window)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
    @Test(arguments: [false, true]) func singleCloseFinishesTextAndConfirmsDiscard(discard: Bool) async throws {
        let (controller, canvas, window) = try editor()
        defer { window.close() }
        var closes = 0
        controller.onClose = { closes += 1 }
        #expect(controller.model.editingText)
        window.performClose(nil)
        try await waitUntil { !controller.model.rendering }
        #expect(!controller.model.editingText && canvas.subviews.isEmpty)
        #expect(controller.model.document.annotations.first?.text == "Uncommitted text")
        try await waitUntil { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        window.performClose(nil)
        #expect(window.attachedSheet === sheet && closes == 0)
        window.endSheet(sheet, returnCode: discard ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        try await waitUntil { discard ? closes == 1 : window.attachedSheet == nil }
        #expect(closes == (discard ? 1 : 0))
        #expect(window.isVisible == !discard)
        if !discard {
            #expect(controller.model.dirty && !controller.model.terminating)
            window.performClose(nil)
            try await waitUntil { window.attachedSheet != nil }
            window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
            try await waitUntil { closes == 1 }
        }
    }
    @Test func internalCloseCancelsDeferredUserClose() async throws {
        let (controller, _, window) = try editor()
        defer { window.close() }
        var closes = 0
        controller.onClose = { closes += 1 }
        window.performClose(nil)
        window.close()
        await controller.model.waitForPendingWork()
        for _ in 0..<20 { await Task.yield() }
        #expect(closes == 1 && !window.isVisible && window.attachedSheet == nil)
    }
    @Test func savedEditorClosesWithoutDiscardConfirmation() async throws {
        let (controller, _, window) = try editor()
        defer { window.close() }
        controller.model.finishEditing()
        await controller.model.waitForPendingWork()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.model.save(to: file, jpeg: false)
        // Closing during save must resume and close once the successful save clears dirty.
        var closes = 0
        controller.onClose = { closes += 1 }
        window.performClose(nil)
        try await waitUntil { closes == 1 }
        #expect(!controller.model.dirty && controller.model.terminating && window.attachedSheet == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
    @Test func internalCloseDismissesPendingDiscardConfirmation() async throws {
        let (controller, _, window) = try editor()
        defer { window.close() }
        var closes = 0
        controller.onClose = { closes += 1 }
        window.performClose(nil)
        try await waitUntil { window.attachedSheet != nil }
        window.close()
        try await waitUntil { window.attachedSheet == nil }
        #expect(closes == 1 && controller.model.terminating && !controller.model.rendering)
        #expect(!window.isVisible)
    }
}
