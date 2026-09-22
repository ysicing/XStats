// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AIUsage

@Suite struct ClaudeLocalUsageTests {
    private func record(id: String = "msg-1", output: Int = 5, final: Bool = false) -> Data {
        Data("""
        {"type":"assistant","timestamp":"2026-09-22T10:00:00Z","message":{"id":"\(id)","model":"claude-sonnet-test","stop_reason":\(final ? "\"end_turn\"" : "null"),"usage":{"input_tokens":10,"cache_read_input_tokens":80,"cache_creation_input_tokens":20,"output_tokens":\(output)}}}
        """.utf8)
    }

    @Test func cacheIsAddedToAnthropicInputExactlyOnce() throws {
        let event = try #require(ClaudeLocalLogParser.parse(record()))
        #expect(event.row.input == 110)
        #expect(event.row.cached == 80)
        #expect(event.row.cacheCreated == 20)
        #expect(event.row.total == 115)
    }

    @Test func finalMessageWinsOverStreamingAndDuplicateCopies() throws {
        let partial = try #require(ClaudeLocalLogParser.parse(record(output: 1)))
        let final = try #require(ClaudeLocalLogParser.parse(record(output: 20, final: true)))
        var events: [String: ClaudeLocalLogParser.Event] = [:]
        for event in [partial, final, partial, final] { ClaudeLocalLogParser.merge(event, into: &events) }
        #expect(events.count == 1)
        #expect(events.values.first?.row.output == 20)
        #expect(events.values.first?.row.records == 1)
    }

    @Test func nestedCacheCreationIsFallbackNotAdditionalUsage() throws {
        let data = Data(#"{"type":"assistant","timestamp":"2026-09-22T10:00:00Z","message":{"id":"nested","model":"claude-test","usage":{"input_tokens":5,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20},"output_tokens":0}}}"#.utf8)
        #expect(try #require(ClaudeLocalLogParser.parse(data)).row.total == 35)
        let fallback = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"cache_creation_input_tokens\":30,", with: "")
        #expect(try #require(ClaudeLocalLogParser.parse(Data(fallback.utf8))).row.total == 35)
    }

    @Test func skipsNonUsageAndInvalidRecords() {
        for raw in ["broken", #"{"type":"user","message":{"usage":{"input_tokens":100}}}"#,
                    #"{"type":"assistant","message":{"id":"x","usage":{"input_tokens":true}}}"#] {
            #expect(ClaudeLocalLogParser.parse(Data(raw.utf8)) == nil)
        }
    }

    @Test func scansSubagentsAndDeduplicatesCopiedMessages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("projects/project/session/subagents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let time = ISO8601DateFormatter().string(from: Date())
        let data = Data(String(decoding: record(final: true), as: UTF8.self)
            .replacingOccurrences(of: "2026-09-22T10:00:00Z", with: time).utf8)
        try data.write(to: root.appendingPathComponent("projects/main.jsonl"))
        try data.write(to: folder.appendingPathComponent("copy.jsonl"))
        let provider = ClaudeLocalUsageProvider(roots: [root])
        let initial = try await provider.fetch()
        #expect(initial.provider == .claude)
        #expect(initial.localUsage?.fileCount == 2)
        #expect(LocalUsageReport.total(initial.localUsage!.rows).total == 115)
        #expect(try await provider.fetch().localUsage == initial.localUsage)
        let more = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "msg-1", with: "msg-2").utf8)
        try more.write(to: folder.appendingPathComponent("another.jsonl"))
        #expect(LocalUsageReport.total(try await provider.fetch().localUsage!.rows).total == 230)
    }
}
