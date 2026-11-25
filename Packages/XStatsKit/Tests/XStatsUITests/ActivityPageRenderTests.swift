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
    let date = Date(timeIntervalSinceReferenceDate: 0)
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
          combinesDevices: true
        )
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
  private func renderRank(
    _ title: String, direction: LayoutDirection, locale: Locale, width: CGFloat
  ) -> CGImage? {
    let renderer = ImageRenderer(
      content: ActivityPageRank(
        title: title, color: .indigo, seconds: 4_200, maximum: 7_200, locale: locale
      )
      .frame(width: width)
      .environment(\.locale, locale)
      .environment(\.layoutDirection, direction))
    renderer.scale = 1
    return renderer.cgImage
  }
}
