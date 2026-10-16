// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Testing
@testable import CaptureCore

struct CaptureWindowStateTests {
  @Test func convertsQuartzBoundsOnDisplaysAboveAndLeftOfPrimary() {
    #expect(
      CaptureGeometry.appKitFrame(
        CGRect(x: -800, y: -300, width: 500, height: 200), primaryHeight: 900)
        == CGRect(x: -800, y: 1000, width: 500, height: 200))
  }
  @Test func windowStateDistinguishesHiddenFromClosedAndRejectsInvalidBounds() throws {
    let bounds = CGRect(x: -300, y: 40, width: 500, height: 300)
    var description: [String: Any] = [
      kCGWindowBounds as String: bounds.dictionaryRepresentation,
      kCGWindowIsOnscreen as String: true,
    ]
    let visible = try #require(CaptureWindowState(description: description))
    #expect(visible.frame == bounds)
    #expect(visible.isOnScreen)
    description[kCGWindowIsOnscreen as String] = false
    #expect(try #require(CaptureWindowState(description: description)).isOnScreen == false)
    #expect(CaptureWindowState(description: [:]) == nil)
    description[kCGWindowBounds as String] = CGRect.zero.dictionaryRepresentation
    #expect(try #require(CaptureWindowState(description: description)).isOnScreen == false)
  }
}
