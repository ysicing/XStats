// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AIUsage

@Suite struct CodexLocalUsageTests {
    private func line(_ payload: String, type: String = "event_msg", time: String = "2026-09-22T10:00:00Z") -> Data {
        Data("{\"timestamp\":\"\(time)\",\"type\":\"\(type)\",\"payload\":\(payload)}".utf8)
    }
    private func usage(_ input: Int, _ output: Int, cached: Int = 0) -> String {
        "{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output)}}}"
    }

    @Test func hourlyBucketsKeepDeltasDeduplicationAndCacheRestoration() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var parser = CodexLocalLogParser(calendar: calendar)
        parser.consume(line(usage(100, 20), time: "2026-09-22T10:15:00Z"))
        parser.consume(line(usage(100, 20), time: "2026-09-22T11:00:00Z"))
        parser = try JSONDecoder().decode(CodexLocalLogParser.self, from: JSONEncoder().encode(parser))
        parser.consume(line(usage(150, 30), time: "2026-09-22T11:15:00Z"))
        let row = try #require(parser.rows.values.first)
        let hour10 = ISO8601DateFormatter().date(from: "2026-09-22T10:00:00Z")!
        let hour11 = hour10.addingTimeInterval(3600)
        #expect(row.hourlyTokens == [hour10: 120, hour11: 60])
        #expect(row.total == 180)
        let merged = LocalUsageReport.aggregated([row, row])
        #expect(merged.count == 1)
        #expect(merged.first?.hourlyTokens == [hour10: 240, hour11: 120])
        #expect(LocalUsageReport.total(merged).hourlyTokens == nil)
    }

    @Test func cumulativeDeltasDeduplicateAndFollowModels() {
        var parser = CodexLocalLogParser()
        parser.consume(line(#"{"model":"model-a"}"#, type: "turn_context"))
        parser.consume(line(usage(100, 20, cached: 80)))
        parser.consume(line(usage(100, 20, cached: 80)))
        parser.consume(line(#"{"model":"model-b"}"#, type: "turn_context"))
        parser.consume(line(usage(150, 30, cached: 90)))
        let rows = Array(parser.rows.values)
        #expect(LocalUsageReport.total(rows).total == 180)
        #expect(LocalUsageReport.total(rows).records == 2)
        #expect(rows.first { $0.model == "model-b" }?.input == 50)
        #expect(LocalUsageReport.total(rows).cached == 90)
    }

    @Test func exactLastUsageWinsAndReasoningIsNotAddedAgain() {
        var parser = CodexLocalLogParser()
        parser.consume(line(#"{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":200},"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":10}}}"#))
        let total = LocalUsageReport.total(Array(parser.rows.values))
        #expect(total.total == 120)
        #expect(total.cached == 80)
        #expect(parser.rows.values.first?.model == "unknown")
    }

    @Test func childHistoryOnlySeedsBaseline() {
        var parser = CodexLocalLogParser()
        parser.consume(line(#"{"id":"child","forked_from_id":"parent"}"#, type: "session_meta"))
        parser.consume(line(usage(1000, 100)))
        parser.consume(line(#"{"type":"task_started","started_at":1790071201}"#))
        parser.consume(line(usage(1100, 120)))
        #expect(LocalUsageReport.total(Array(parser.rows.values)).total == 120)
    }

    /// 2026 年起的 Codex 构建发的 task_started 不带 started_at。以前要求这个字段存在
    /// 才结束回放，于是子代理会话永远停在回放状态，全部 Token 被当成基线丢掉。
    @Test func liveTurnCountsWhenTaskStartedOmitsStartedAt() {
        var parser = CodexLocalLogParser()
        parser.consume(line(#"{"id":"child","source":{"subagent":"review"}}"#, type: "session_meta"))
        parser.consume(line(#"{"type":"task_started","turn_id":"t1","model_context_window":258400,"collaboration_mode_kind":"default"}"#))
        parser.consume(line(usage(100, 20)))
        #expect(LocalUsageReport.total(Array(parser.rows.values)).total == 120)
    }

    /// 子代理的 started_at 是父级回合的开始时间，天然早于子会话文件的创建时间。
    /// 拿它和创建时间比较会把第一个真实回合误判成回放。
    @Test func subagentFirstTurnSurvivesAParentStartedAt() {
        var parser = CodexLocalLogParser()
        parser.consume(line(#"{"id":"child","source":{"subagent":"review"}}"#,
                            type: "session_meta", time: "2026-09-22T10:00:00Z"))
        parser.consume(line(#"{"type":"task_started","started_at":1758535200}"#, time: "2026-09-22T10:00:02Z"))
        parser.consume(line(usage(100, 20), time: "2026-09-22T10:00:05Z"))
        #expect(LocalUsageReport.total(Array(parser.rows.values)).total == 120)
    }

    @Test func rootNullParentAndMalformedLinesAreHandled() {
        var parser = CodexLocalLogParser()
        parser.consume(line(#"{"id":"root","forked_from_id":null,"source":{"subagent":null}}"#, type: "session_meta"))
        parser.consume(Data("broken".utf8))
        parser.consume(line(usage(10, 2)))
        #expect(LocalUsageReport.total(Array(parser.rows.values)).total == 12)
    }

    @Test func legacyCheckpointRebuildsHourlyDetailsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions/a.jsonl")
        let time = ISO8601DateFormatter().string(from: Date())
        var content = line(usage(100, 20), time: time)
        var legacy = CodexLocalLogParser()
        legacy.consume(content)
        for key in legacy.rows.keys { legacy.rows[key]?.hourlyTokens = nil }
        content.append(10)
        try content.write(to: url)
        let database = root.appendingPathComponent("usage-cache.sqlite")
        let store = try UsageScanStore(url: database)
        _ = try store.scan(url: url, source: "codex-v2", initial: legacy) { _, _ in }
        let provider = CodexLocalUsageProvider(root: root)
        let first = try #require(try await provider.fetch().localUsage)
        #expect(first.rows.first?.hourlyTokens?.values.reduce(0, +) == 120)
        #expect(try await CodexLocalUsageProvider(root: root).fetch().localUsage == first)
        #expect(try await provider.fetch().localUsage == first)
    }

    @Test func repeatedClockHourKeepsTwoAbsoluteBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var parser = CodexLocalLogParser(calendar: calendar)
        parser.consume(line(usage(100, 20), time: "2026-11-01T08:30:00Z"))
        parser.consume(line(usage(150, 30), time: "2026-11-01T09:30:00Z"))
        let hours = try #require(parser.rows.values.first?.hourlyTokens)
        #expect(hours.count == 2)
        #expect(hours.values.reduce(0, +) == 180)
        #expect(hours.keys.allSatisfy { calendar.component(.hour, from: $0) == 1 })
    }

    @Test(arguments: ["2026-10-04T12:00:00Z", "2026-04-05T12:00:00Z"])
    func halfHourDSTKeepsEveryParsedTokenInTheChart(_ timestamp: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Australia/Lord_Howe"))
        let now = try #require(ISO8601DateFormatter().date(from: timestamp))
        let start = calendar.startOfDay(for: now)
        var parser = CodexLocalLogParser(calendar: calendar)
        var time = start
        var input = 0
        while time <= now {
            input += 10
            parser.consume(line(usage(input, 0), time: ISO8601DateFormatter().string(from: time)))
            time = time.addingTimeInterval(1800)
        }
        let rows = LocalUsageReport.aggregated(parser.rows.values)
        let series = UsageTimeSeries(rows: rows, mode: .daily, now: now, calendar: calendar)
        #expect(series.buckets.reduce(0) { $0 + $1.total } == LocalUsageReport.total(rows).total)
        let hours = Set(rows.flatMap { Array(($0.hourlyTokens ?? [:]).keys) })
        #expect(hours.isSubset(of: Set(series.buckets.map(\.start))))
    }

    @Test func archiveDedupAndChangedFilesRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["sessions", "archived_sessions"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let time = ISO8601DateFormatter().string(from: Date())
        var content = line(#"{"id":"same"}"#, type: "session_meta", time: time)
        content.append(10); content.append(line(usage(100, 20), time: time)); content.append(10)
        let active = root.appendingPathComponent("sessions/a.jsonl")
        try content.write(to: active)
        try content.write(to: root.appendingPathComponent("archived_sessions/copy.jsonl"))
        let provider = CodexLocalUsageProvider(root: root)
        let initial = try await provider.fetch()
        #expect(LocalUsageReport.total(initial.localUsage!.rows).total == 120)
        let cached = try await provider.fetch()
        #expect(cached.localUsage == initial.localUsage)
        content.append(line(usage(150, 30), time: time)); content.append(10)
        try content.write(to: active)
        let changed = try await provider.fetch()
        #expect(LocalUsageReport.total(changed.localUsage!.rows).total == 180)
    }

    /// `ModelTokenUsage.id` 是“日期 + 模型”，多个会话文件必须先合并成一行，
    /// 否则 report.rows 里会出现大量重复 id，视图按 id 渲染就会错。
    @Test func sameDayAndModelFromDifferentSessionsCollapseToOneRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let time = ISO8601DateFormatter().string(from: Date())
        for session in ["one", "two"] {
            var content = line("{\"id\":\"\(session)\"}", type: "session_meta", time: time)
            content.append(10)
            content.append(line(#"{"model":"gpt-5"}"#, type: "turn_context", time: time)); content.append(10)
            content.append(line(usage(100, 20), time: time)); content.append(10)
            try content.write(to: root.appendingPathComponent("sessions/\(session).jsonl"))
        }
        let report = try #require(try await CodexLocalUsageProvider(root: root).fetch().localUsage)
        #expect(report.rows.count == 1)
        #expect(Set(report.rows.map(\.id)).count == report.rows.count)
        #expect(LocalUsageReport.total(report.rows).total == 240)
        #expect(LocalUsageReport.total(report.rows).records == 2)
    }

    @Test func dateAndModelFiltersUseOneConsistentTotal() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")!
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let report = LocalUsageReport(rows: [
            ModelTokenUsage(day: today, model: "a", input: 100, cached: 20, output: 10, records: 1),
            ModelTokenUsage(day: yesterday, model: "b", input: 200, output: 20, records: 1)
        ], fileCount: 2)
        #expect(LocalUsageReport.total(report.selected(days: 1, now: now, calendar: calendar)).total == 110)
        #expect(LocalUsageReport.total(report.selected(days: 7, model: "b", now: now, calendar: calendar)).total == 220)
    }
}
