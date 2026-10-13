// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import ScreenCaptureKit
import CaptureCore
import Localization

@MainActor final class CaptureSelection {
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<ScreenCaptureSource?, any Error>?
    private var eventMonitor: Any?
    func select(mode: CaptureMode, content: SCShareableContent) async throws -> ScreenCaptureSource? {
        try Task.checkCancellation()
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !excluded.isEmpty else { throw CaptureError.captureFailed }
        let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let orderedIDs = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let windows = orderedIDs.compactMap { windowsByID[$0] }.filter { $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                for screen in NSScreen.screens {
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                          let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                    let panel = SelectionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    panel.level = .screenSaver; panel.isOpaque = false; panel.backgroundColor = .clear
                    panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), mode: mode, screen: screen, display: display, windows: windows)
                    view.onSelection = { [weak self] region, window in
                        guard let self else { return }
                        if let window { self.finish(ScreenCaptureSource(window: window, displayID: id)) }
                        else if let region {
                            do {
                                let converted = try CaptureGeometry.region(region, in: screen.frame, scale: screen.backingScaleFactor)
                                self.finish(ScreenCaptureSource(display: display, excludedApps: excluded, region: converted))
                            } catch { self.finish(nil) }
                        } else { self.finish(ScreenCaptureSource(display: display, excludedApps: excluded)) }
                    }
                    panel.contentView = view
                    panel.orderFrontRegardless()
                    self.panels.append(panel)
                }
                self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 { self?.finish(nil); return nil }
                    return event
                }
                NSApp.activate(ignoringOtherApps: true)
                self.panels.first?.makeKey()
                if self.panels.isEmpty { self.finish(nil) }
            }
        } onCancel: { Task { @MainActor in self.finish(nil) } }
    }
    func cancel() { finish(nil) }
    private func finish(_ source: ScreenCaptureSource?) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        let continuation = self.continuation; self.continuation = nil
        continuation?.resume(returning: source)
    }
}

@MainActor private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor private final class SelectionView: NSView {
    let mode: CaptureMode
    let screen: NSScreen
    let display: SCDisplay
    let windows: [SCWindow]
    var onSelection: (CGRect?, SCWindow?) -> Void = { _, _ in }
    private var start: CGPoint?
    private var current: CGPoint?
    private var hovered: SCWindow?
    override var acceptsFirstResponder: Bool { true }
    init(frame: CGRect, mode: CaptureMode, screen: NSScreen, display: SCDisplay, windows: [SCWindow]) {
        self.mode = mode; self.screen = screen; self.display = display; self.windows = windows
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    private func quartzPoint(_ event: NSEvent) -> CGPoint {
        let global = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: global.x, y: height - global.y)
    }
    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        let point = quartzPoint(event)
        let candidate = windows.first { $0.frame.contains(point) }
        if candidate?.windowID != hovered?.windowID { hovered = candidate; needsDisplay = true }
    }
    override func mouseDown(with event: NSEvent) {
        switch mode {
        case .display: onSelection(nil, nil)
        case .window:
            mouseMoved(with: event)
            if let hovered { onSelection(nil, hovered) }
        case .region: start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard mode == .region else { return }
        let point = convert(event.locationInWindow, from: nil)
        current = CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard mode == .region, let start, let current else { return }
        let rect = CGRect(x: min(start.x, current.x) + screen.frame.minX, y: min(start.y, current.y) + screen.frame.minY,
                          width: abs(start.x - current.x), height: abs(start.y - current.y))
        if rect.width >= 2, rect.height >= 2 { onSelection(rect, nil) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill(); bounds.fill()
        var highlight: CGRect?
        if let start, let current { highlight = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y)) }
        if mode == .window, let hovered {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            highlight = CGRect(x: hovered.frame.minX - screen.frame.minX, y: primaryHeight - hovered.frame.maxY - screen.frame.minY,
                               width: hovered.frame.width, height: hovered.frame.height)
        }
        if let highlight {
            NSColor.clear.setFill(); highlight.fill(using: .copy)
            NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: highlight).stroke()
        }
        let text = switch mode {
        case .region: tr("拖动选择区域，按 Esc 取消")
        case .window: tr("点击窗口，按 Esc 取消")
        case .display: tr("点击要捕获的屏幕，按 Esc 取消")
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 90), withAttributes: attributes)
    }
}
