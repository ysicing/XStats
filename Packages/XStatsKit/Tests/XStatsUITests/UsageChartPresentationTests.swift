// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Foundation
import Testing
@testable import XStatsUI

struct UsageChartPresentationTests {
    @Test func compactCumulativeUsesMonthlySummaryAndChartImmediately() throws {
        let mode = UsageChartPresentation.mode(.cumulative, compact: true)
        #expect(mode == .monthly)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z"))
        let today = calendar.startOfDay(for: now)
        let rows = [0, 29, 30, 364].map { offset in
            ModelTokenUsage(day: calendar.date(byAdding: .day, value: -offset, to: today)!, model: "fixture", input: 100)
        }
        let report = LocalUsageReport(rows: rows, fileCount: 1)
        let summary = report.summary(mode: mode, now: now, calendar: calendar)
        let series = UsageTimeSeries(rows: report.selected(days: 30, now: now, calendar: calendar), mode: mode, now: now, calendar: calendar)
        #expect(LocalUsageReport.total(summary).total == 200)
        #expect(series.buckets.count == 30)
        #expect(series.buckets.reduce(0) { $0 + $1.total } == LocalUsageReport.total(summary).total)
    }

    @Test(arguments: UsageActivityMode.allCases)
    func normalModesAndFullWindowRemainUnchanged(_ mode: UsageActivityMode) {
        #expect(UsageChartPresentation.mode(mode, compact: false) == mode)
        if mode != .cumulative { #expect(UsageChartPresentation.mode(mode, compact: true) == mode) }
    }

    @Test(arguments: [true, false])
    func shortAxesHaveUniqueValidIdentities(_ narrow: Bool) {
        #expect(UsageChartPresentation.tickIndices(count: 0, narrow: narrow) == [])
        #expect(UsageChartPresentation.tickIndices(count: 1, narrow: narrow) == [0])
        #expect(UsageChartPresentation.tickIndices(count: 2, narrow: narrow) == [0, 1])
        for count in [3, 7, 23, 24, 25, 30] {
            let indices = UsageChartPresentation.tickIndices(count: count, narrow: narrow)
            #expect(indices == indices.sorted())
            #expect(indices.count == Set(indices).count)
            #expect(indices.allSatisfy { (0..<count).contains($0) })
            #expect(indices.first == 0 && indices.last == count - 1)
        }
    }
}
