// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
import Localization
import CaptureCore
@testable import CaptureUI

@Suite @MainActor struct ImageEditorLanguageTests {
    @Test func languageRefreshKeepsTheDocumentAndUpdatesTheWindowTitle() throws {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let editor = ImageEditorWindow(image: try #require(context.makeImage()))
        defer { editor.window?.orderOut(nil) }
        let annotation = ImageAnnotation(tool: .text, points: [CGPoint(x: 2, y: 2)], text: "annotation")
        editor.model.document.add(annotation)
        editor.model.select(annotation.id)
        editor.model.dirty = true
        let oldContent = try #require(editor.window?.contentView)
        // 显式语言不改变进程全局 L10n，避免影响并行测试。
        for language in [AppLanguage.german, .arabic, .chinese] {
            editor.applyLanguage(language)
            #expect(editor.window?.title == L10n.translate("截图编辑", language: language))
            #expect(editor.window?.contentView !== oldContent)
            #expect(editor.model.selected == annotation)
            #expect(editor.model.dirty)
            #expect(editor.model.document.original.width == 20)
        }
    }
    @Test func canvasLayoutDoesNotGrowTheWindowWhenPropertiesChange() async throws {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let editor = ImageEditorWindow(image: try #require(context.makeImage()))
        let window = try #require(editor.window)
        defer { window.orderOut(nil) }
        let initial = window.frame.size
        let availableHeight = window.contentRect(forFrameRect: window.frame).height
        for tool in [ImageTool.arrow, .text, .rectangle, .redact, .pen] {
            editor.model.tool = tool
            for _ in 0..<3 {
                window.contentView?.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            #expect(window.frame.size == initial)
            #expect((window.contentView?.fittingSize.height ?? .infinity) <= availableHeight)
        }
    }
}
