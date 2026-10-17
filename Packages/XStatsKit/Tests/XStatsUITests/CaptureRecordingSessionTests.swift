// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import CaptureUI
@testable import XStatsUI

@MainActor struct CaptureRecordingSessionTests {
  @Test func switchingHostsEndsCaptureThroughFirstResponder() throws {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let button = ShortcutButton()
    window.contentView = button
    let session = ShortcutRecordingSession()
    let captureID = UUID()
    let xstatsID = UUID()
    var xstatsRecording = false
    var captureStops = 0
    button.onRecordingChanged = { recording in
      if recording {
        session.begin(captureID) { window.makeFirstResponder(nil) }
      } else {
        captureStops += 1
        session.end(captureID)
      }
    }
    defer {
      session.cancel()
      button.onRecordingChanged = { _ in }
      window.close()
    }

    button.performClick(nil)
    try #require(button.recording)
    #expect(window.firstResponder === button)
    session.begin(xstatsID) {
      xstatsRecording = false
      session.end(xstatsID)
    }
    xstatsRecording = true
    #expect(!button.recording && captureStops == 1)
    #expect(window.firstResponder !== button)

    button.performClick(nil)
    #expect(button.recording && !xstatsRecording)
    // 旧宿主的迟到清理不能清除当前 Capture 所有者。
    session.end(xstatsID)
    session.cancel()
    #expect(!button.recording && captureStops == 2)
  }
}
