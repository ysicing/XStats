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

    @Test func rootNullParentAndMalformedLinesAreHandled() {
        var parser = CodexLocalLogParser()
        parser.consume(line(#"{"id":"root","forked_from_id":null,"source":{"subagent":null}}"#, type: "session_meta"))
        parser.consume(Data("broken".utf8))
        parser.consume(line(usage(10, 2)))
        #expect(LocalUsageReport.total(Array(parser.rows.values)).total == 12)
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
