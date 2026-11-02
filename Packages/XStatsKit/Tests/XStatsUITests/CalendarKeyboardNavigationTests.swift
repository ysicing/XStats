// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct CalendarKeyboardNavigationTests {
  @Test(
    arguments: zip(
      [
        NSEvent.ModifierFlags(),
        [.numericPad, .function],
        [.numericPad, .function, .capsLock],
        [.numericPad, .function, .command],
        [.numericPad, .function, .option],
        [.numericPad, .function, .control],
        [.numericPad, .function, .shift],
      ],
      ["2027", "2027", "2027", "2026", "2026", "2026", "2026"]
    ))
  func arrowKeysRespectShortcutModifiers(
    modifiers: NSEvent.ModifierFlags, expectedYear: String
  ) async throws {
    let suite = "CalendarKeyboardNavigationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.calendarFeatures = []
    settings.calendarPreferences.showHolidayOverview = false
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    let date = try #require(ISO8601DateFormatter().date(from: "2026-12-15T04:00:00Z"))
    let panel = StatusPanel(width: 520, minHeight: 500) {
      CalendarPopover(referenceDate: date, firstWeekday: 1).environment(model)
    } measuring: {
      Color.clear.frame(width: 520, height: 500)
    }
    panel.isPinned = true
    defer {
      panel.isPinned = false
      panel.dismiss()
      panel.close()
    }
    let screen = try #require(NSScreen.main)
    panel.present(
      below: NSRect(
        x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 20, height: 20),
      on: screen)
    try await Task.sleep(for: .milliseconds(150))
    let content = try #require(panel.contentView)
    let year = try #require(yearField(in: content))
    #expect(year.stringValue == "2026")
    let right = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: panel.windowNumber, context: nil,
        characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
        isARepeat: false, keyCode: 124))
    panel.sendEvent(right)
    try await Task.sleep(for: .milliseconds(100))
    #expect(year.stringValue == expectedYear)
    let left = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: panel.windowNumber, context: nil,
        characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}",
        isARepeat: false, keyCode: 123))
    panel.sendEvent(left)
    try await Task.sleep(for: .milliseconds(100))
    #expect(year.stringValue == "2026")
  }

  private func yearField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    for child in view.subviews {
      if let field = yearField(in: child) { return field }
    }
    return nil
  }
}
