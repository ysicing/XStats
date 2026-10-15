// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit

/// Non-interactive recording chrome; its window ID also belongs in the SC filter.
@MainActor final class RecordingRangeIndicator {
    private(set) var panel: NSPanel?
    private(set) var paused = false
    var windowIDs: Set<CGWindowID> { Set(panel.map { [CGWindowID($0.windowNumber)] } ?? []) }

    func update(frame: CGRect, paused: Bool, visible: Bool) {
        self.paused = paused
        guard visible, !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else {
            panel?.orderOut(nil); return
        }
        if panel == nil {
            let panel = NSPanel(contentRect: frame.insetBy(dx: -3, dy: -3), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.level = .screenSaver; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.sharingType = .none
            panel.contentView = RecordingRangeView()
            self.panel = panel
        }
        guard let panel, let view = panel.contentView as? RecordingRangeView else { return }
        let outer = frame.insetBy(dx: -3, dy: -3)
        if panel.frame != outer { panel.setFrame(outer, display: false) }
        if view.paused != paused { view.paused = paused; view.needsDisplay = true }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    static func controlFrame(size: CGSize, target: CGRect, screens: [CGRect]) -> CGRect {
        let candidates = [
            CGRect(x: target.midX - size.width / 2, y: target.minY - size.height - 12, width: size.width, height: size.height),
            CGRect(x: target.midX - size.width / 2, y: target.maxY + 12, width: size.width, height: size.height),
            CGRect(x: target.maxX + 12, y: target.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: target.minX - size.width - 12, y: target.midY - size.height / 2, width: size.width, height: size.height)
        ]
        if let frame = candidates.first(where: { candidate in screens.contains { $0.contains(candidate) } }) { return frame }
        guard let screen = screens.first(where: { $0.intersects(target) }) ?? screens.first else { return candidates[0] }
        return CGRect(x: max(screen.minX, screen.maxX - size.width - 16),
                      y: max(screen.minY, screen.maxY - size.height - 16), width: size.width, height: size.height)
    }
    func close() {
        panel?.orderOut(nil); panel?.close(); panel = nil
    }
}

@MainActor private final class RecordingRangeView: NSView {
    var paused = false
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        if paused { path.setLineDash([6, 4], count: 2, phase: 0) }
        (paused ? NSColor.secondaryLabelColor : .systemRed).setStroke()
        path.stroke()
    }
}
