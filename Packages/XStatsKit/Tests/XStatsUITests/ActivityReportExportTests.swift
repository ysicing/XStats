// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

struct ActivityReportExportTests {
  @Test func markdownContainsTheSelectedScopeAndEscapesTableCells() throws {
    let markdown = try render(.markdown, period: .week, device: "Desk | Mac")
    #expect(markdown.hasPrefix("# Activity Report\n"))
    #expect(markdown.contains("- Time Range · Week\n"))
    #expect(markdown.contains("- Time range · Jan 1, 2001 – Jan 7, 2001\n"))
    #expect(markdown.contains("- Device · Desk \\| Mac\n"))
    #expect(markdown.contains("- Total Active Time · "))
    #expect(markdown.contains("## Category Summary\n"))
    #expect(markdown.contains("## Top Apps\n"))
    #expect(markdown.contains("| Editor, \"Pro\" \\| \\[Lab\\] Next | Work |"))
    #expect(!markdown.contains("Remote App"))
  }

  @Test func csvQuotesFieldsAndKeepsMetadataAndNumericDurations() throws {
    let csv = try render(.csv, period: .month, device: "=Example,\"Mac\"")
    #expect(csv.hasPrefix("\"Type\",\"Name\",\"Categories\",\"Active Time (seconds)\"\r\n"))
    #expect(csv.contains("\"Time Range\",\"Month\",\"\",\"\"\r\n"))
    #expect(csv.contains("\"Device\",\"'=Example,\"\"Mac\"\"\",\"\",\"\"\r\n"))
    #expect(csv.contains("\"Total Active Time\",\"\",\"\",\"12.5\"\r\n"))
    #expect(csv.contains("\"Category Summary\",\"\",\"Work\",\"12.5\"\r\n"))
    #expect(
      csv.contains("\"Top Apps\",\"Editor, \"\"Pro\"\" | [Lab]\nNext\",\"Work\",\"12.5\"\r\n"))
    #expect(!csv.contains("Remote App"))
  }

  private func render(
    _ format: ActivityReportExport.Format, period: ActivityPagePeriod, device: String
  ) throws -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    calendar.firstWeekday = 2
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let interval = try #require(calendar.dateInterval(of: period.component, for: start))
    let local = UUID()
    let sessions = [
      ActivitySession(
        id: UUID(), deviceID: local, appID: "editor", appName: "Editor, \"Pro\" | [Lab]\nNext",
        category: "work", start: start, end: start.addingTimeInterval(12.5)),
      ActivitySession(
        id: UUID(), deviceID: UUID(), appID: "remote", appName: "Remote App", category: "other",
        start: start, end: start.addingTimeInterval(60)),
    ]
    let report = try ActivityPageAnalytics.make(
      sessions: sessions, interval: interval, period: period, calendar: calendar, deviceID: local)
    return ActivityReportExport.render(
      report, format: format, interval: interval, period: period, deviceName: device,
      calendar: calendar, locale: Locale(identifier: "en_US"), language: .english)
  }
}
