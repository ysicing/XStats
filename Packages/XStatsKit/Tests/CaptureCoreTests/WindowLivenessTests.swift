// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
@testable import CaptureCore

@Suite @MainActor struct WindowLivenessTests {
    @Test func lookupFindsOnlyTheRequestedWindowIncludingWhenHidden() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 180, height: 90),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderBack(nil)
        let id = CGWindowID(window.windowNumber)
        #expect(ScreenRecorder.isWindowAvailable(id))
        window.orderOut(nil)
        #expect(ScreenRecorder.isWindowAvailable(id))
        #expect(!ScreenRecorder.isWindowAvailable(kCGNullWindowID))
        #expect(!ScreenRecorder.isWindowAvailable(.max))
    }
}
