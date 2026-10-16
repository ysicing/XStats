// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AIUsage

@Suite struct UsageOverflowTests {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }

  @Test func restoredRowsSaturateAcrossModelsHoursDaysAndSummaryWindows() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z"))
    let day = calendar.startOfDay(for: now)
    let row = ModelTokenUsage(
      day: day, model: "a", input: .max, cached: .max, output: .max, records: .max,
      cacheCreated: .max, hourlyTokens: [day: .max])
    let restored = try JSONDecoder().decode(ModelTokenUsage.self, from: JSONEncoder().encode(row))
    let rows = [
      restored, restored,
      ModelTokenUsage(day: day.addingTimeInterval(-86400), model: "b", input: .max),
    ]
    let report = LocalUsageReport(rows: rows, fileCount: 1)
    #expect(restored.total == Int.max)
    let combined = LocalUsageReport.total(rows)
    #expect(combined.input == Int.max)
    #expect(combined.cached == Int.max)
    #expect(combined.cacheCreated == Int.max)
    #expect(combined.output == Int.max)
    #expect(combined.records == Int.max)
    #expect(LocalUsageReport.aggregated(rows).last?.hourlyTokens?[day] == Int.max)
    #expect(LocalUsageReport.models(rows).allSatisfy { $0.total == Int.max })
    for mode in UsageActivityMode.allCases {
      #expect(
        LocalUsageReport.total(report.summary(mode: mode, now: now, calendar: calendar)).total
          == Int.max)
      let series = UsageTimeSeries(rows: rows, mode: mode, now: now, calendar: calendar)
      #expect(series.buckets.contains { $0.total == Int.max })
      #expect(series.buckets.allSatisfy { $0.total >= 0 })
    }
    let activity = UsageActivity(rows: rows, now: now, calendar: calendar)
    #expect(activity.total == Int.max)
    #expect(activity.daily[day] == Int.max)
  }

  @Test func negativeCachedCountsCannotUnderflowOrCancelValidCounts() throws {
    let day = calendar.startOfDay(for: Date())
    let invalid = ModelTokenUsage(
      day: day, model: "a", input: .min, output: .min, hourlyTokens: [day: .min])
    let restored = try JSONDecoder().decode(
      ModelTokenUsage.self, from: JSONEncoder().encode(invalid))
    let valid = ModelTokenUsage(day: day, model: "a", input: 12, output: 3, hourlyTokens: [day: 15])
    #expect(restored.total == 0)
    #expect(LocalUsageReport.total([restored, valid]).total == 15)
    #expect(LocalUsageReport.total([valid, restored]).total == 15)
    #expect(
      UsageTimeSeries(rows: [restored, valid], mode: .daily, calendar: calendar).buckets.first?
        .total == 15)
  }

  @Test func codexRepeatedValidLargeEventsAndRestoredCheckpointDoNotOverflow() throws {
    var parser = CodexLocalLogParser(calendar: calendar)
    let line = Data(
      #"{"timestamp":"2026-09-22T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999999999999999,"cached_input_tokens":999999999999999,"output_tokens":999999999999999}}}}"#
        .utf8)
    for _ in 0..<10_000 { parser.consume(line) }
    parser = try JSONDecoder().decode(CodexLocalLogParser.self, from: JSONEncoder().encode(parser))
    parser.consume(line)
    let row = try #require(parser.rows.values.first)
    #expect(row.input == Int.max)
    #expect(row.cached == Int.max)
    #expect(row.output == Int.max)
    #expect(row.total == Int.max)
    #expect(row.hourlyTokens?.values.first == Int.max)
    #expect(row.records == 10_001)
  }

  @Test func codexRestoredNegativeBaselineAndMaximumCountersAreSafe() throws {
    var parser = CodexLocalLogParser(calendar: calendar)
    let line = Data(
      #"{"timestamp":"2026-09-22T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":1}}}}"#
        .utf8)
    parser.consume(line)
    var checkpoint = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(parser)) as? [String: Any])
    checkpoint["previous"] = ["input": Int.min, "cached": Int.min, "output": Int.min]
    parser = try JSONDecoder().decode(
      CodexLocalLogParser.self, from: JSONSerialization.data(withJSONObject: checkpoint))
    let key = try #require(parser.rows.keys.first)
    parser.rows[key]?.records = Int.max
    parser.rows[key]?.input = Int.max
    parser.rows[key]?.output = Int.max
    parser.consume(line)
    let row = try #require(parser.rows[key])
    #expect(row.total == Int.max)
    #expect(row.records == Int.max)
    #expect(row.hourlyTokens?.values.first == 4)
  }

  @Test func claudeLargeParsedEventsRemainSafeWhenAggregated() throws {
    let line = Data(
      #"{"type":"assistant","timestamp":"2026-09-22T10:00:00Z","message":{"id":"large","model":"claude-test","usage":{"input_tokens":999999999999999,"cache_read_input_tokens":999999999999999,"cache_creation_input_tokens":999999999999999,"output_tokens":999999999999999}}}"#
        .utf8)
    let event = try #require(ClaudeLocalLogParser.parse(line, calendar: calendar))
    #expect(event.row.total == 3_999_999_999_999_996)
    let restored = try JSONDecoder().decode(
      ClaudeLocalLogParser.Event.self, from: JSONEncoder().encode(event))
    let row = try #require(
      LocalUsageReport.aggregated(repeatElement(restored.row, count: 10_000)).first)
    #expect(row.total == Int.max)
    #expect(row.hourlyTokens?.values.first == Int.max)
    #expect(row.records == 10_000)
  }
}
