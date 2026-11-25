// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import XStatsUI

struct ActivityPageRenderTests {
  @MainActor
  @Test func rankingWrapsLongLabelsInConstrainedLeftToRightAndRightToLeftLayouts() throws {
    let width: CGFloat = 280
    let fixtures: [(LayoutDirection, Locale, String, String)] = [
      (.leftToRight, Locale(identifier: "de_DE"), "Arbeit", "Kommunikation und Zusammenarbeit"),
      (.rightToLeft, Locale(identifier: "ar_SA"), "عمل", "التواصل والعمل الجماعي والمراسلات"),
    ]

    for (direction, locale, shortTitle, longTitle) in fixtures {
      let shortRow = try #require(
        renderRank(
          shortTitle, direction: direction, locale: locale, width: width))
      let longRow = try #require(
        renderRank(
          longTitle, direction: direction, locale: locale, width: width))
      #expect(longRow.width == Int(width))
      #expect(longRow.height > shortRow.height)
    }
  }

  @MainActor
  @Test func nativeTimelinesRenderAtConstrainedWidthInRightToLeftLayout() throws {
    let locale = Locale(identifier: "ar_SA")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let date = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 19)))
    let deviceID = UUID()
    let sessions = [
      ActivitySession(
        id: UUID(), deviceID: deviceID, appID: "editor", appName: "Editor", category: "work",
        start: date.addingTimeInterval(3_600), end: date.addingTimeInterval(7_200)),
      ActivitySession(
        id: UUID(), deviceID: UUID(), appID: "browser", appName: "Browser", category: "browsing",
        start: date.addingTimeInterval(5_400), end: date.addingTimeInterval(9_000)),
    ]
    let previewDirectory = ProcessInfo.processInfo.environment["XSTATS_ACTIVITY_PREVIEW_DIR"]
      .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    if let previewDirectory {
      try FileManager.default.createDirectory(
        at: previewDirectory, withIntermediateDirectories: true)
    }

    for period in ActivityPagePeriod.allCases {
      let interval = try #require(calendar.dateInterval(of: period.component, for: date))
      let report = try ActivityPageAnalytics.make(
        sessions: sessions, interval: interval, period: period, calendar: calendar, deviceID: nil)
      let renderer = ImageRenderer(
        content: ActivityPageTimeline(
          report: report, interval: interval, period: period, calendar: calendar, locale: locale,
          combinesDevices: true, now: date.addingTimeInterval(10_800), animateEntry: false,
          deviceNames: [:], localID: deviceID, openDay: { _ in }
        ) {
          Text(
            ActivityPageFormat.dateTitle(
              interval, period: period, calendar: calendar, locale: locale)
          )
          .font(.headline)
        }
        .frame(width: 320)
        .background(DS.Palette.background)
        .environment(\.colorScheme, .light)
        .environment(\.locale, locale)
        .environment(\.layoutDirection, .rightToLeft))
      let scale = previewDirectory == nil ? 1 : 2
      renderer.scale = CGFloat(scale)

      let image = try #require(renderer.cgImage)
      if let previewDirectory {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(
          to: previewDirectory.appendingPathComponent("activity-\(period)-rtl.png"),
          options: .atomic)
      }
      #expect(image.width == 320 * scale)
      #expect(image.height > 100 * scale)
    }
  }

  @MainActor
  @Test(arguments: ActivityPagePeriod.allCases)
  func rendersActivityOverviewWithRankings(period: ActivityPagePeriod) throws {
    let locale = Locale(identifier: "zh_CN")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    calendar.firstWeekday = 2
    let date = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 18)))
    let interval = try #require(calendar.dateInterval(of: period.component, for: date))
    let localID = UUID()
    let remoteID = UUID()
    let apps = [
      ("Xcode", "work"), ("Safari", "browsing"), ("Terminal", "work"),
      ("Messages", "communication"), ("Music", "entertainment"), ("Finder", "other"),
    ]
    var sessions = try (0..<25).flatMap { day in
      try apps.enumerated().map { index, app in
        let start = try #require(
          calendar.date(from: DateComponents(year: 2026, month: 11, day: day + 1, hour: 8 + index)))
        return ActivitySession(
          id: UUID(), deviceID: localID, appID: app.0, appName: app.0, category: app.1,
          start: start,
          end: start.addingTimeInterval(Double(3_540 - (day * 211 + index * 613) % 2_820)))
      }
    }
    let overlapStart = try #require(
      calendar.date(bySettingHour: 10, minute: 15, second: 0, of: date))
    sessions.append(
      ActivitySession(
        id: UUID(), deviceID: remoteID, appID: "Safari", appName: "Safari", category: "browsing",
        start: overlapStart, end: overlapStart.addingTimeInterval(3_000)))
    let report = try ActivityPageAnalytics.make(
      sessions: sessions, interval: interval, period: period, calendar: calendar, deviceID: nil)
    let previewDirectory = ProcessInfo.processInfo.environment["XSTATS_ACTIVITY_PREVIEW_DIR"]
      .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    if let previewDirectory {
      try FileManager.default.createDirectory(
        at: previewDirectory, withIntermediateDirectories: true)
    }
    var heights: [Int] = []
    for width in [840, 640, 480] {
      let renderer = ImageRenderer(
        content: VStack(alignment: .leading, spacing: DS.Space.s4) {
          Text("应用活动").font(.title2.bold())
          ActivityPageTimeline(
            report: report, interval: interval, period: period, calendar: calendar, locale: locale,
            combinesDevices: true, now: date, animateEntry: false,
            deviceNames: [:], localID: localID, openDay: { _ in }
          ) {
            Text(
              ActivityPageFormat.dateTitle(
                interval, period: period, calendar: calendar, locale: locale)
            )
            .font(.headline)
          }
          ActivityPageRankings(report: report, locale: locale) { _ in }
        }
        .padding(DS.Space.s4)
        .frame(width: CGFloat(width))
        .background(DS.Palette.background)
        .environment(\.colorScheme, .light)
        .environment(\.locale, locale)
        .environment(\.isSnapshot, true))
      let image = try #require(renderer.cgImage)
      #expect(image.width == width)
      heights.append(image.height)
      if let previewDirectory {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(
          to: previewDirectory.appendingPathComponent("activity-\(period)-\(width).png"),
          options: .atomic)
      }
    }
    #expect(heights[2] > heights[1])
  }

  @MainActor
  private func renderRank(
    _ title: String, direction: LayoutDirection, locale: Locale, width: CGFloat
  ) -> CGImage? {
    let renderer = ImageRenderer(
      content: ActivityPageRank(
        entries: [.init(id: .work, title: title, color: .indigo, seconds: 4_200)],
        total: 7_200, locale: locale, stacksDuration: false
      )
      .frame(width: width)
      .environment(\.locale, locale)
      .environment(\.layoutDirection, direction))
    renderer.scale = 1
    return renderer.cgImage
  }
}
