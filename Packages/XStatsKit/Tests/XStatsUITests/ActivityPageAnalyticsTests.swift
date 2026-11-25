// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

struct ActivityPageAnalyticsTests {
  private let local = UUID()
  private let remote = UUID()
  private let midnight = Date(timeIntervalSinceReferenceDate: 0)

  @Test func clipsBothEdgesAndIgnoresSessionsTouchingTheDay() throws {
    let calendar = utcCalendar
    let interval = try #require(calendar.dateInterval(of: .day, for: midnight))
    let crossesStart = session(from: -600, to: 300)
    let crossesEnd = session(from: 86_100, to: 86_700)
    let report = try ActivityPageAnalytics.make(
      sessions: [
        session(from: -600, to: 0), crossesEnd, crossesStart,
        session(from: 86_400, to: 87_000),
      ], interval: interval, period: .day, calendar: calendar, deviceID: nil)

    let app = try #require(report.apps.first)
    #expect(report.seconds == 600)
    #expect(report.days.map(\.seconds) == [600])
    #expect(report.categories.map(\.seconds) == [600])
    #expect(app.segments.map(\.sessionID) == [crossesEnd.id, crossesStart.id])
    #expect(app.segments.map(\.start) == [at(86_100), interval.start])
    #expect(app.segments.map(\.end) == [interval.end, at(300)])
  }

  @Test func simultaneousDevicesAddTimeAndCanBeViewedSeparately() throws {
    let calendar = utcCalendar
    let interval = try #require(calendar.dateInterval(of: .day, for: midnight))
    let sessions = [
      session(from: 0, to: 600),
      session(on: remote, from: 0, to: 900),
      session(on: remote, appID: "browser", category: "browsing", from: 900, to: 1200),
      session(appID: "chat", category: "communication", from: 600, to: 720),
    ]
    let combined = try ActivityPageAnalytics.make(
      sessions: sessions, interval: interval, period: .day, calendar: calendar, deviceID: nil)
    let localOnly = try ActivityPageAnalytics.make(
      sessions: sessions, interval: interval, period: .day, calendar: calendar, deviceID: local)
    let remoteOnly = try ActivityPageAnalytics.make(
      sessions: sessions, interval: interval, period: .day, calendar: calendar, deviceID: remote)

    #expect(combined.seconds == 1_920)
    #expect(combined.seconds == localOnly.seconds + remoteOnly.seconds)
    #expect(combined.apps.map(\.id) == ["editor", "browser", "chat"])
    #expect(combined.apps.map(\.seconds) == [1_500, 300, 120])
    #expect(combined.categories.map(\.id) == [.work, .browsing, .communication])
    #expect(combined.categories.map(\.seconds) == [1_500, 300, 120])
    #expect(Set(combined.lanes.map(\.id)) == [local, remote])
    #expect(localOnly.deviceIDs == [local])
    #expect(remoteOnly.deviceIDs == [remote])
  }

  @Test func nestedForegroundOverlapsKeepTotalsRanksTimelineAndDetailsInAgreement() throws {
    let calendar = utcCalendar
    let interval = try #require(calendar.dateInterval(of: .day, for: midnight))
    let editor = session(from: -60, to: 600)
    let browser = session(appID: "browser", category: "browsing", from: 120, to: 420)
    let chat = session(appID: "chat", category: "communication", from: 240, to: 300)
    let remoteEditor = session(on: remote, from: 180, to: 360)
    let result = try ActivityPageAnalytics.make(
      sessions: [chat, remoteEditor, editor, browser], interval: interval, period: .day,
      calendar: calendar, deviceID: nil)

    let localLane = try #require(result.lanes.first { $0.id == local })
    let localSegments = localLane.segments.sorted { $0.start < $1.start }
    let browserDetail = try #require(result.apps.first { $0.id == "browser" })

    #expect(result.seconds == 780)
    #expect(result.days.map(\.seconds) == [780])
    #expect(
      result.days.first?.secondsByCategory == [.work: 480, .browsing: 240, .communication: 60])
    #expect(result.categories.map(\.id) == [.work, .browsing, .communication])
    #expect(result.categories.map(\.seconds) == [480, 240, 60])
    #expect(result.apps.map(\.id) == ["editor", "browser", "chat"])
    #expect(result.apps.map(\.seconds) == [480, 240, 60])
    #expect(
      localSegments.map(\.sessionID) == [editor.id, browser.id, chat.id, browser.id, editor.id])
    #expect(localSegments.map(\.start) == [at(0), at(120), at(240), at(300), at(420)])
    #expect(localSegments.map(\.end) == [at(120), at(240), at(300), at(420), at(600)])
    #expect(Set(localSegments.map(\.id)).count == localSegments.count)
    #expect(browserDetail.segments.map(\.start) == [at(300), at(120)])
    #expect(browserDetail.segments.map(\.seconds) == [120, 120])
  }

  @Test func overlapPriorityUsesOriginalStartBeforeClippingAndBreaksTiesByID() throws {
    let calendar = utcCalendar
    let interval = try #require(calendar.dateInterval(of: .day, for: midnight))
    let olderID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    let preferredID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let otherID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    let older = session(id: olderID, from: -120, to: 360)
    let preferred = session(
      id: preferredID, appID: "browser", category: "browsing", from: -60, to: 120)
    let other = session(
      id: otherID, appID: "game", category: "entertainment", from: -60, to: 240)
    let input = [other, preferred, older]

    for sessions in [input, Array(input.reversed())] {
      let report = try ActivityPageAnalytics.make(
        sessions: sessions, interval: interval, period: .day, calendar: calendar, deviceID: local)
      let lane = try #require(report.lanes.first)
      let segments = lane.segments.sorted { $0.start < $1.start }
      #expect(report.seconds == 360)
      #expect(segments.map(\.sessionID) == [preferredID, otherID, olderID])
      #expect(segments.map(\.start) == [at(0), at(120), at(240)])
      #expect(segments.map(\.seconds) == [120, 120, 120])
    }
  }

  @Test func checkpointSegmentsCoalesceInDetailAndTimelineWithoutBridgingGaps() throws {
    let calendar = utcCalendar
    let interval = try #require(calendar.dateInterval(of: .day, for: midnight))
    let first = session(from: -300, to: 300)
    let checkpoint = session(from: 300, to: 600)
    let afterGap = session(from: 660, to: 960)
    let categoryChange = session(category: "other", from: 960, to: 1_260)
    let result = try ActivityPageAnalytics.make(
      sessions: [
        categoryChange, afterGap, checkpoint, session(on: remote, from: 0, to: 300), first,
      ], interval: interval, period: .day, calendar: calendar, deviceID: nil)

    let app = try #require(result.apps.first)
    let localLane = try #require(result.lanes.first { $0.id == local })
    let remoteLane = try #require(result.lanes.first { $0.id == remote })
    #expect(app.segments.count == 4)
    #expect(localLane.segments.map(\.sessionID) == [first.id, afterGap.id, categoryChange.id])
    #expect(localLane.segments.map(\.seconds) == [600, 300, 300])
    #expect(remoteLane.segments.map(\.seconds) == [300])
    #expect(app.seconds == 1_500)
    #expect(app.segments.reduce(0) { $0 + $1.seconds } == app.seconds)
  }

  @Test func weekAndMonthBinsRespectCivilMidnightAcrossDaylightSaving() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 1
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let march8 = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
    let march9 = try #require(calendar.date(byAdding: .day, value: 1, to: march8))
    let activity = session(
      from: march8.timeIntervalSince(midnight) - 1_800,
      to: march9.timeIntervalSince(midnight) + 900)

    let week = try #require(
      calendar.dateInterval(of: ActivityPagePeriod.week.component, for: march8))
    let weekly = try ActivityPageAnalytics.make(
      sessions: [activity], interval: week, period: .week, calendar: calendar, deviceID: nil)
    #expect(weekly.days.count == 7)
    #expect(weekly.days.prefix(2).map(\.seconds) == [23 * 3_600, 900])
    #expect(weekly.seconds == 23 * 3_600 + 900)
    #expect(weekly.lanes.isEmpty)

    let month = try #require(
      calendar.dateInterval(of: ActivityPagePeriod.month.component, for: march8))
    let monthly = try ActivityPageAnalytics.make(
      sessions: [activity], interval: month, period: .month, calendar: calendar, deviceID: nil)
    try #require(monthly.days.count == 31)
    #expect(monthly.days[6...8].map(\.seconds) == [1_800, 23 * 3_600, 900])
    #expect(monthly.days[7].interval.end == march9)
    #expect(monthly.seconds == monthly.days.reduce(0) { $0 + $1.seconds })
    #expect(monthly.days.last?.interval.end == month.end)
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func at(_ seconds: TimeInterval) -> Date {
    midnight.addingTimeInterval(seconds)
  }

  private func session(
    id: UUID = UUID(), on device: UUID? = nil, appID: String = "editor", category: String = "work",
    from start: TimeInterval, to end: TimeInterval
  ) -> ActivitySession {
    ActivitySession(
      id: id, deviceID: device ?? local, appID: appID, appName: appID,
      category: category, start: at(start), end: at(end))
  }
}
