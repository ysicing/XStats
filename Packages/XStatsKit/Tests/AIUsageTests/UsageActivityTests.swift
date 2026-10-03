// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AIUsage

@Suite struct UsageActivityTests {
    @Test func summaryFollowsTodayThisWeekAndAnnualCumulative() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-09-22T12:00:00Z")!
        func row(_ date: String, _ value: Int, model: String = "a") -> ModelTokenUsage {
            ModelTokenUsage(day: formatter.date(from: date + "T00:00:00Z")!, model: model, input: value)
        }
        let report = LocalUsageReport(rows: [row("2026-09-22", 1), row("2026-09-21", 10),
            row("2026-09-20", 100), row("2026-09-01", 1000), row("2026-08-31", 10000),
            row("2026-09-23", 99999), row("2026-09-22", 2, model: "b")], fileCount: 1)
        #expect(LocalUsageReport.total(report.summary(mode: .daily, now: now, calendar: calendar)).total == 3)
        #expect(LocalUsageReport.total(report.summary(mode: .weekly, now: now, calendar: calendar)).total == 13)
        #expect(LocalUsageReport.total(report.summary(mode: .cumulative, now: now, calendar: calendar)).total == 11113)
        #expect(LocalUsageReport.total(report.summary(mode: .cumulative, model: "a", now: now, calendar: calendar)).total == 11111)
        #expect(LocalUsageReport.total(report.selected(days: 365, now: now, calendar: calendar)).total == 11113)
    }
    @Test(arguments: ["2026-01-01T12:00:00Z", "2026-03-01T12:00:00Z"])
    func cumulativeSummaryMatchesChartAcrossYearAndMonthBoundaries(_ timestamp: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(ISO8601DateFormatter().date(from: timestamp))
        let today = calendar.startOfDay(for: now)
        let rows = [-1, 0, 31, 364, 365].flatMap { ago in
            ["a", "b"].map { model in
                ModelTokenUsage(day: calendar.date(byAdding: .day, value: -ago, to: today)!,
                                model: model, input: model == "a" ? 100 : 200, output: 10)
            }
        }
        let report = LocalUsageReport(rows: rows, fileCount: 1)
        for model: String? in [nil, "a", "b"] {
            let summary = report.summary(mode: .cumulative, model: model, now: now, calendar: calendar)
            let activity = UsageActivity(rows: report.selected(days: 365, model: model, now: now, calendar: calendar),
                                         now: now, calendar: calendar)
            let total = LocalUsageReport.total(summary).total
            #expect(total == activity.peak(for: .cumulative))
            #expect(total == (model == nil ? 960 : model == "a" ? 330 : 630))
            #expect(LocalUsageReport.models(summary).reduce(0) { $0 + $1.total } == total)
        }
    }

    @Test func weeklyAndCumulativeColorsDistinguishUsageWithoutLightingZero() {
        #expect(UsageActivity.colorIntensity(value: 0, peak: 100, mode: .weekly) == 0)
        #expect(UsageActivity.colorIntensity(value: 100, peak: 100, mode: .cumulative) == 1)
        let values = [1, 10, 25, 50, 100]
        for mode in [UsageActivityMode.weekly, .cumulative] {
            let colors = values.map { UsageActivity.colorIntensity(value: $0, peak: 100, mode: mode) }
            #expect(colors == colors.sorted())
            #expect(Set(colors).count == values.count)
        }
        #expect(UsageActivity.colorIntensity(value: 10, peak: 100, mode: .weekly)
                > UsageActivity.colorIntensity(value: 10, peak: 100, mode: .cumulative))
    }
    @Test func modesShareYearAndWeeklyAccumulationIsNotRepeatedPerDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")!
        let today = calendar.startOfDay(for: now)
        func row(_ ago: Int, _ count: Int) -> ModelTokenUsage {
            ModelTokenUsage(day: calendar.date(byAdding: .day, value: -ago, to: today)!, model: "test", input: count)
        }
        let activity = UsageActivity(rows: [row(0, 20), row(1, 10), row(2, 100), row(365, 999), row(-1, 999)], now: now, calendar: calendar)
        #expect(activity.weeks.flatMap(\.days).compactMap { $0 }.count == 365)
        #expect(activity.weeks.last?.total == 30)
        #expect(activity.weeks.last?.cumulative == 130)
        #expect(activity.weeks.last?.end == today)
        #expect(activity.peak(for: .daily) == 100)
        #expect(activity.peak(for: .weekly) == 100)
        #expect(activity.peak(for: .cumulative) == 130)
        #expect(activity.weeks.reduce(0) { $0 + $1.total } == 130)
        let accumulated = activity.weeks.map(\.cumulative)
        #expect(accumulated == accumulated.sorted())
    }

    @Test func emptyAndSmallBarsHaveHonestCellCounts() {
        #expect(UsageActivity.filledCells(value: 0, peak: 100) == 0)
        #expect(UsageActivity.filledCells(value: 1, peak: 100) == 1)
        #expect(UsageActivity.filledCells(value: 50, peak: 100) == 4)
        #expect(UsageActivity.filledCells(value: 100, peak: 100) == 7)
        #expect(UsageActivity(rows: []).peak(for: .cumulative) == 0)
    }
}
