// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureCore
import Localization
import Testing
@testable import CaptureUI

@Suite @MainActor struct SelectionViewTests {
    @Test(arguments: [CaptureRequest.Action.screenshot, .record])
    func regionStaysEditableUntilExplicitConfirmation(_ action: CaptureRequest.Action) throws {
        let (view, window) = makeView(mode: .region, action: action)
        defer { window.close() }
        var submitted: [CGRect?] = []
        view.onSelection = { rect, _ in submitted.append(rect) }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), window: window))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 200, y: 180), window: window))
        view.confirmSelection()
        #expect(submitted.isEmpty)
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 200, y: 180), window: window))
        #expect(view.isReady)
        #expect(submitted.isEmpty)
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 140, y: 140), window: window))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 180, y: 170), window: window))
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 240, y: 170), window: window))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 280, y: 170), window: window))
        #expect(submitted.isEmpty)
        view.confirmSelection()
        #expect(submitted.count == 1)
        #expect(submitted.first! == CGRect(x: -1300, y: 230, width: 140, height: 80))
        view.confirmSelection()
        #expect(submitted.count == 1)
    }
    @Test func displayClickMarksTheTargetWithoutStartingCapture() throws {
        let (view, window) = makeView(mode: .display, action: .record)
        defer { window.close() }
        var calls = 0
        view.onSelection = { rect, selectedWindow in
            #expect(rect == nil); #expect(selectedWindow == nil); calls += 1
        }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 300, y: 200), window: window))
        #expect(view.isReady)
        #expect(calls == 0)
        view.confirmSelection()
        #expect(calls == 1)
    }
    @Test func resetAndEmptyWindowSelectionCannotSubmitAnOldDraft() throws {
        for mode in [CaptureMode.region, .display, .window] {
            let (view, window) = makeView(mode: mode, action: .screenshot)
            defer { window.close() }
            var calls = 0
            view.onSelection = { _, _ in calls += 1 }
            view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), window: window))
            view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 220, y: 190), window: window))
            view.resetSelection()
            view.confirmSelection()
            #expect(!view.isReady)
            #expect(calls == 0)
        }
    }
    @Test func nativeResetAndCancelButtonsDispatchWithoutCapturing() throws {
        let (view, window) = makeView(mode: .display, action: .record)
        defer { window.close() }
        var captures = 0, resets = 0, cancels = 0
        view.onSelection = { _, _ in captures += 1 }
        view.onReset = { [weak view] in resets += 1; view?.resetSelection() }
        view.onCancel = { cancels += 1 }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 200, y: 200), window: window))
        let toolbar = try #require(view.subviews.first as? NSVisualEffectView)
        let stack = try #require(toolbar.subviews.first as? NSStackView)
        let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        let reset = try #require(buttons.first { $0.toolTip == L10n.translate("重新选择", language: .chinese) })
        reset.performClick(nil)
        #expect(resets == 1)
        #expect(!view.isReady)
        #expect(toolbar.isHidden)
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 200, y: 200), window: window))
        let cancel = try #require(buttons.first { $0.toolTip == L10n.translate("取消", language: .chinese) })
        cancel.performClick(nil)
        #expect(cancels == 1)
        #expect(captures == 0)
    }
    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func nativeToolbarFitsAllLanguagesAndRetinaDimensions(_ language: AppLanguage) throws {
        let (view, window) = makeView(mode: .region, action: .record, language: language)
        defer { window.close() }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 0, y: 0), window: window))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 500, y: 400), window: window))
        let toolbar = try #require(view.subviews.first as? NSVisualEffectView)
        toolbar.layoutSubtreeIfNeeded()
        let stack = try #require(toolbar.subviews.first as? NSStackView)
        #expect(!toolbar.isHidden)
        #expect(view.bounds.contains(toolbar.frame))
        #expect(stack.userInterfaceLayoutDirection == (language == .arabic ? .rightToLeft : .leftToRight))
        let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 3)
        #expect(buttons.first?.title == L10n.translate("开始录屏", language: language))
        for button in buttons { #expect(button.frame.width >= button.intrinsicContentSize.width) }
        let label = try #require(stack.arrangedSubviews.first as? NSTextField)
        #expect(label.cell?.baseWritingDirection == .leftToRight)
        let width = 1000.formatted(.number.locale(L10n.locale(for: language)))
        let height = 800.formatted(.number.locale(L10n.locale(for: language)))
        #expect(label.stringValue == L10n.translate("\(width) × \(height) 像素", language: language))
    }
    private func makeView(mode: CaptureMode, action: CaptureRequest.Action, language: AppLanguage = .chinese) -> (SelectionView, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 500, height: 400), mode: mode, action: action,
            screenFrame: CGRect(x: -1440, y: 100, width: 500, height: 400), scale: 2, windows: [], language: language)
        window.contentView = view
        return (view, window)
    }
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
