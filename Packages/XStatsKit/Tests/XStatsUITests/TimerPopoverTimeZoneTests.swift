// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI
import Testing
import WidgetData
@testable import XStatsUI

@MainActor struct TimerPopoverTimeZoneTests {
  @Test func clockOrderAndLocalZoneFollowTheSystem() {
    #expect(ClockTimeZone.allCases == [.local, .utc, .pacific])
    #expect(ClockTimeZone.local.timeZone == .autoupdatingCurrent)
    #expect(ClockTimeZone.utc.timeZone.secondsFromGMT() == 0)
    #expect(ClockTimeZone.pacific.timeZone.identifier == "America/Los_Angeles")
  }

  @Test(arguments: [
    ("Asia/Singapore", "zh_CN", "新加坡时间"),
    ("Asia/Singapore", "en_US", "Singapore Time"),
    ("America/Los_Angeles", "zh_CN", "洛杉矶时间"),
    ("America/Los_Angeles", "en_US", "Los Angeles Time"),
  ])
  func localClockNameUsesTheSystemZone(
    identifier: String, locale: String, name: String
  ) throws {
    var style = ClockTimeZone.local.locationStyle(locale: Locale(identifier: locale))
    #expect(style.timeZone == .autoupdatingCurrent)
    style.timeZone = try #require(TimeZone(identifier: identifier))
    for instant in ["2026-01-01T00:30:00Z", "2026-07-01T00:30:00Z"] {
      let date = try #require(ISO8601DateFormatter().date(from: instant))
      #expect(style.format(date) == name)
    }
  }

  @Test(arguments: [
    ("2026-01-01T00:30:00Z", "16:30:00", -8),
    ("2026-07-01T00:30:00Z", "17:30:00", -7),
    ("2026-03-08T09:59:59Z", "01:59:59", -8),
    ("2026-03-08T10:00:00Z", "03:00:00", -7),
    ("2026-11-01T08:59:59Z", "01:59:59", -7),
    ("2026-11-01T09:00:00Z", "01:00:00", -8),
  ])
  func pacificClockFollowsDaylightSaving(instant: String, time: String, offset: Int) throws {
    let date = try #require(ISO8601DateFormatter().date(from: instant))
    let locale = Locale(identifier: "en_GB")
    #expect(ClockTimeZone.pacific.timeStyle(locale: locale).format(date) == time)
    #expect(
      ClockTimeZone.pacific.timeStyle(locale: locale, includesSeconds: false).format(date)
        == String(time.prefix(5)))
    #expect(ClockTimeZone.pacific.timeZone.secondsFromGMT(for: date) == offset * 3600)
  }

  @Test func datesMakePreviousDayAndYearVisible() throws {
    let date = try #require(ISO8601DateFormatter().date(from: "2026-01-01T00:30:00Z"))
    #expect(
      ClockTimeZone.utc.timeStyle(locale: Locale(identifier: "en_GB")).format(date) == "00:30:00")
    #expect(
      ClockTimeZone.utc.dateStyle(locale: Locale(identifier: "en_US")).format(date) == "Jan 1, 2026"
    )
    #expect(
      ClockTimeZone.pacific.dateStyle(locale: Locale(identifier: "en_US")).format(date)
        == "Dec 31, 2025")
    #expect(
      ClockTimeZone.pacific.timeStyle(locale: Locale(identifier: "en_US")).format(date).contains(
        "PM"))
    #expect(
      ClockTimeZone.pacific.timeStyle(
        locale: Locale(identifier: "en_US"), includesSeconds: false
      ).format(date).contains("PM"))
  }

  @Test(arguments: [
    "zh_Hans", "zh_Hans_CN", "zh_Hans_SG", "zh_Hant", "zh_Hant_TW", "zh_Hant_HK",
  ])
  func chineseClocksDistinguishMidnightAndNoon(localeID: String) throws {
    let locale = Locale(identifier: localeID)
    for (instant, time) in [
      ("2026-11-06T08:50:41Z", "00:50:41"),
      ("2026-11-06T20:50:41Z", "12:50:41"),
      ("2026-11-07T07:50:41Z", "23:50:41"),
    ] {
      let date = try #require(ISO8601DateFormatter().date(from: instant))
      #expect(ClockTimeZone.pacific.timeStyle(locale: locale).format(date) == time)
      #expect(
        ClockTimeZone.pacific.timeStyle(locale: locale, includesSeconds: false).format(date)
          == String(time.prefix(5)))
    }
  }

  @Test func clockPagePreservesTimersAndDisablesTimerKeys() async throws {
    let suite = "TimerPopoverTimeZoneTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.restEnabled = true
    settings.timerPreferences.mode = .stopwatch
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    model.timer.startPauseStopwatch()
    let host = NSHostingView(
      rootView: TimerPopover(showsTimeZones: true, openPage: {}, showHUD: {}, close: {})
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
    try await settle(host)
    #expect(settings.timerPreferences.mode == .stopwatch)
    #expect(model.timer.stopwatch.isRunning)
    #expect(host.fittingSize.width == 400)
    let keyboard = try #require(descendant(TimerKeyboardShortcuts.KeyView.self, in: host))
    for (key, code, modifiers) in [
      (" ", UInt16(49), NSEvent.ModifierFlags()), ("l", UInt16(37), .command),
    ] {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: modifiers,
          timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
          charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
      #expect(keyboard.handle?(event) == false)
    }
    #expect(model.timer.stopwatch.isRunning && model.timer.stopwatch.laps.isEmpty)
    host.frame.size = host.fittingSize
    try await settle(host)
    try capturePreview(host, name: "popover")
    await model.wellness.prepareForTermination()
  }

  @Test func clockPanelRefreshesAndReleasesContentOnClose() async throws {
    let suite = "TimerPopoverTimeZoneTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    let panel = StatusPanel(
      width: 400, minHeight: 180,
      content: {
        TimerPopover(showsTimeZones: true, openPage: {}, showHUD: {}, close: {})
          .environment(model)
      },
      measuring: {
        TimerPopover(showsTimeZones: true, openPage: {}, showHUD: {}, close: {})
          .environment(model).environment(\.isSnapshot, true)
      })
    panel.isPinned = true
    defer {
      panel.isPinned = false
      panel.dismiss()
      model.timer.stop()
      model.rest.stop()
    }
    for _ in 0..<2 {
      panel.present(
        below: NSRect(x: 400, y: 600, width: 24, height: 24), on: NSScreen.main)
      let content = try #require(panel.contentView)
      try await settle(content)
      let first = try bitmap(content)
      try await Task.sleep(for: .milliseconds(1200))
      try await settle(content)
      let second = try bitmap(content)
      #expect(first != second)
      #expect(!model.timer.hasDisplayTimer && !model.timer.hasDeadlineTimer)
      #expect(panel.frame.width == 400 && panel.frame.height >= 180)
      panel.isPinned = false
      panel.dismiss()
      #expect(panel.contentView == nil && !panel.isVisible)
      panel.isPinned = true
    }
    await model.wellness.prepareForTermination()
  }

  @Test(arguments: [
    AppLanguage.chinese, .traditionalChinese, .english, .japanese, .korean,
    .german, .spanish, .french, .arabic,
  ])
  func localizedClocksFitThePanel(language: AppLanguage) async throws {
    let locale = L10n.locale(for: language)
    let host = NSHostingView(
      rootView: TimerTimeZoneContent(language: language)
        .environment(\.locale, locale)
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.isSnapshot, true).frame(width: 368)
        .background(Color(nsColor: .windowBackgroundColor)))
    host.frame.size = host.fittingSize
    let window = NSWindow(
      contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: host.fittingSize),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.close() }
    try await settle(host)
    #expect(host.fittingSize.width == 368)
    #expect(host.fittingSize.height >= 150 && host.fittingSize.height < 240)
    try capturePreview(host, name: "clocks-\(language.languageCode)")
  }

  private func bitmap(_ view: NSView) throws -> Data {
    let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: image)
    return try #require(image.representation(using: .png, properties: [:]))
  }

  private func capturePreview(_ view: NSView, name: String) throws {
    if let directory = ProcessInfo.processInfo.environment["XSTATS_TIME_ZONE_PREVIEW_DIR"] {
      let url = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      let original = view.window?.appearance
      defer { view.window?.appearance = original }
      for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        view.window?.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        view.display()
        try bitmap(view).write(to: url.appendingPathComponent("\(name)-\(suffix).png"))
      }
    }
  }

  private func settle(_ view: NSView) async throws {
    try await Task.sleep(for: .milliseconds(30))
    view.layoutSubtreeIfNeeded()
  }

  private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let result = view as? T { return result }
    for child in view.subviews {
      if let result = descendant(type, in: child) { return result }
    }
    return nil
  }
}
