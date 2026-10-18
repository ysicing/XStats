// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor struct TimerPopoverRestTests {
  /// 挂载真实休息页，验证原生刻度与视图注入的快捷键动作共用现有配置。
  @Test func restPagePreservesRunningTimersAndUsesSavedBreakDurations() async throws {
    let suite = "TimerPopoverRestTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.restEnabled = true
    settings.restBreakMinutes = 3
    settings.restLongBreakMinutes = 20
    settings.timerPreferences.mode = .stopwatch
    settings.timerPreferences.sleepDisplayDuringBreak = true
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    model.timer.startPauseStopwatch()
    var closed = 0
    let host = NSHostingView(
      rootView: TimerPopover(showsRest: true, openPage: {}, showHUD: {}, close: { closed += 1 })
        .environment(model).environment(\.isSnapshot, true))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 360),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.close()
      model.timer.stop()
      model.rest.stop()
    }
    host.layoutSubtreeIfNeeded()
    try await settle(host)
    #expect(settings.timerPreferences.mode == .stopwatch)
    #expect(model.timer.stopwatch.isRunning)
    let ruler = try #require(descendant(TimerRulerControl.self, in: host))
    #expect(ruler.selectedMinutes == 3)
    #expect(ruler.accessibilityPerformIncrement())
    try await settle(host)
    #expect(settings.restBreakMinutes == 5)
    #expect(settings.restLongBreakMinutes == 20)
    var sleepRequests = 0
    model.wellness.onSleepDisplay = { sleepRequests += 1 }
    let keyboard = try #require(descendant(TimerKeyboardShortcuts.KeyView.self, in: host))
    let space = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ",
        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    #expect(keyboard.handle?(space) == true)
    try await settle(host)
    #expect(closed == 1 && sleepRequests == 1)
    #expect(model.wellness.isEyeRestActive && model.wellness.breakKind == .short)
    #expect(model.wellness.eyeRestDuration == 300)
    #expect(model.timer.stopwatch.isRunning)
    #expect(settings.timerPreferences.mode == .stopwatch)
    model.wellness.finishEyeRest(completed: false)
    await model.wellness.prepareForTermination()
  }

  @Test func restSpaceStartsLongBreakWithoutStartingSelectedTimerOrRecordingLap() async throws {
    let suite = "TimerPopoverRestTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.restEnabled = true
    settings.restLongBreakMinutes = 20
    settings.timerPreferences.mode = .stopwatch
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    var closed = 0
    let host = NSHostingView(
      rootView: TimerPopover(
        showsRest: true, breakKind: .long,
        openPage: {}, showHUD: {}, close: { closed += 1 }
      ).environment(model)
        .environment(\.isSnapshot, true))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 360),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.close()
      model.timer.stop()
      model.rest.stop()
    }
    host.layoutSubtreeIfNeeded()
    let keyboard = try #require(descendant(TimerKeyboardShortcuts.KeyView.self, in: host))
    let lap = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "l",
        charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37))
    #expect(keyboard.handle?(lap) == false)
    #expect(model.timer.stopwatch.laps.isEmpty)
    let space = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ",
        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    model.timerShortcutBlockers.insert(UUID())
    #expect(keyboard.handle?(space) == false)
    #expect(!model.wellness.isEyeRestActive)
    model.timerShortcutBlockers.removeAll()
    #expect(keyboard.handle?(space) == true)
    #expect(closed == 1)
    #expect(model.wellness.breakKind == .long && model.wellness.eyeRestDuration == 1200)
    #expect(!model.timer.stopwatch.isRunning && !model.timer.countdown.isRunning)
    #expect(keyboard.handle?(space) == false)
    model.wellness.finishEyeRest(completed: false)
    await model.wellness.prepareForTermination()
  }

  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(25))
    host.layoutSubtreeIfNeeded()
  }

  private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let result = view as? T { return result }
    for child in view.subviews {
      if let result = descendant(type, in: child) { return result }
    }
    return nil
  }
}
