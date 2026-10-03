// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AIUsage

@Suite struct UsageActivityTests {
    @Test func summariesUseTodayAndRollingSevenThirtyAnd365Days() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-01-02T12:00:00Z"))
        let today = calendar.startOfDay(for: now)
        let rows = [-1, 0, 6, 7, 29, 30, 364, 365].map { ago in
            ModelTokenUsage(day: calendar.date(byAdding: .day, value: -ago, to: today)!, model: "a", input: 100)
        }
        let report = LocalUsageReport(rows: rows, fileCount: 1)
        for (mode, total) in [(UsageActivityMode.daily, 100), (.weekly, 200), (.monthly, 400), (.cumulative, 600)] {
            let summary = report.summary(mode: mode, now: now, calendar: calendar)
            #expect(LocalUsageReport.total(summary).total == total)
            #expect(report.summary(mode: mode, model: "missing", now: now, calendar: calendar).isEmpty)
            if mode == .weekly || mode == .monthly {
                let series = UsageTimeSeries(rows: rows, mode: mode, now: now, calendar: calendar)
                #expect(series.buckets.count == mode.days)
                #expect(series.buckets.reduce(0) { $0 + $1.total } == total)
                #expect(series.buckets.last?.start == today)
            }
        }
    }

    @Test(arguments: ["2026-01-01T12:00:00Z", "2026-03-01T12:00:00Z"])
    func cumulativeSummaryMatchesDailyHeatmapAcrossBoundaries(_ timestamp: String) throws {
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
            #expect(total == activity.total)
            #expect(total == (model == nil ? 960 : model == "a" ? 330 : 630))
            #expect(activity.peak == (model == nil ? 320 : model == "a" ? 110 : 210))
            #expect(activity.weeks.flatMap(\.days).compactMap { $0 }.count == 365)
            #expect(LocalUsageReport.models(summary).reduce(0) { $0 + $1.total } == total)
        }
    }

    @Test(arguments: [("2026-03-08T20:00:00Z", 23), ("2026-11-01T20:00:00Z", 25), ("2026-10-03T20:00:00Z", 24)])
    func hourlyChartHonorsDayLengthAndRepeatedHours(_ timestamp: String, _ count: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(ISO8601DateFormatter().date(from: timestamp))
        let empty = UsageTimeSeries(rows: [], mode: .daily, now: now, calendar: calendar)
        #expect(empty.buckets.count == count)
        #expect(Set(empty.buckets.map(\.id)).count == count)
        let hour1 = empty.buckets[1].start
        let hour2 = empty.buckets[2].start
        let row = ModelTokenUsage(day: calendar.startOfDay(for: now), model: "a", input: 100, output: 20,
                                  hourlyTokens: [hour1: 50, hour2: 70])
        let series = UsageTimeSeries(rows: [row], mode: .daily, now: now, calendar: calendar)
        #expect(series.buckets[1].total == 50)
        #expect(series.buckets[2].total == 70)
        #expect(series.buckets.reduce(0) { $0 + $1.total } == row.total)
        #expect(!series.hasMissingHourlyData)
    }

    @Test func legacyDataDoesNotInventMidnightUsage() throws {
        let now = Date()
        let old = ModelTokenUsage(day: Calendar.current.startOfDay(for: now), model: "a", input: 100)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "hourlyTokens")
        let restored = try JSONDecoder().decode(ModelTokenUsage.self, from: JSONSerialization.data(withJSONObject: json))
        let series = UsageTimeSeries(rows: [restored], mode: .daily, now: now)
        #expect(series.hasMissingHourlyData)
        #expect(series.buckets.allSatisfy { $0.total == 0 })
        let hourly = ModelTokenUsage(day: old.day, model: "a", input: 100, hourlyTokens: [old.day: 100])
        #expect(LocalUsageReport.aggregated([old, hourly]).first?.hourlyTokens == nil)
        #expect(LocalUsageReport.aggregated([hourly, old]).first?.hourlyTokens == nil)
    }
}
