// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Quartz global bounds and current desktop visibility of one capture target.
public struct CaptureWindowState: Sendable, Equatable {
    public let frame: CGRect
    public let isOnScreen: Bool

    init?(description: [String: Any]) {
        guard let bounds = description[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              !frame.isNull, !frame.isInfinite else { return nil }
        self.frame = frame
        // WindowServer can temporarily report empty bounds for a live window.
        // Keep its identity alive, while suppressing an unusable outline.
        isOnScreen = frame.width > 0 && frame.height > 0
            && (description[kCGWindowIsOnscreen as String] as? Bool) == true
    }
    static func read(_ windowID: CGWindowID) -> CaptureWindowState? {
        guard windowID != kCGNullWindowID else { return nil }
        // No CF object callbacks: this API takes integer-valued window IDs.
        var identifier = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let identifiers = CFArrayCreate(kCFAllocatorDefault, &identifier, 1, nil),
              let windows = CGWindowListCreateDescriptionFromArray(identifiers) as? [[String: Any]],
              let description = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }) else { return nil }
        return CaptureWindowState(description: description)
    }
}
