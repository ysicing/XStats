// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AIUsage

@Suite struct UsageScanStoreTests {
    private struct Sum: Codable { var total = 0 }
    private func scan(_ store: UsageScanStore, _ file: URL, source: String = "test") throws -> Int {
        try store.scan(url: file, source: source, initial: Sum()) { state, line in
            state.total += Int(String(decoding: line, as: UTF8.self)) ?? 0
        }.total
    }

    @Test func restartUsesDatabaseAndAppendOnlyReadsSuffix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("cache.sqlite")
        let file = root.appendingPathComponent("usage.jsonl")
        var first: UsageScanStore? = try UsageScanStore(url: db)
        try Data(String(repeating: "1\n", count: 100_000).utf8).write(to: file)
        #expect(try scan(first!, file) == 100_000)
        first = nil
        let restarted = try UsageScanStore(url: db)
        #expect(try scan(restarted, file) == 100_000)
        #expect(restarted.bytesRead == 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("2\n".utf8)); try handle.close()
        #expect(try scan(restarted, file) == 100_002)
        #expect(restarted.bytesRead < 20_000)
    }

    @Test func unfinishedLastLineDoesNotDoubleCountAfterAppend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("cache.sqlite")
        let file = root.appendingPathComponent("usage.jsonl")
        let store = try UsageScanStore(url: db)
        try Data("1\n2".utf8).write(to: file)
        #expect(try scan(store, file) == 3)
        let restarted = try UsageScanStore(url: db)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("\n3\n".utf8)); try handle.close()
        #expect(try scan(restarted, file) == 6)
    }

    @Test func truncationAndReplacementRebuildOnlyThatFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageScanStore(url: root.appendingPathComponent("cache.sqlite"))
        let file = root.appendingPathComponent("usage.jsonl")
        try Data("100\n200\n".utf8).write(to: file)
        #expect(try scan(store, file) == 300)
        try Data("3\n".utf8).write(to: file)
        #expect(try scan(store, file) == 3)
        try Data("5\n6\n7\n".utf8).write(to: file, options: .atomic)
        #expect(try scan(store, file) == 18)
    }

    /// 归档会改变 rollout 路径、项目目录会被删掉、解析口径升级会换命名空间。
    /// 这些行都不会再被扫到，留着就是让缓存库连同完整解析状态一起无限增长。
    @Test func pruneDropsVanishedFilesAndOldNamespacesButKeepsOtherSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try UsageScanStore(url: root.appendingPathComponent("cache.sqlite"))

        var files: [String: URL] = [:]
        for name in ["kept", "archived", "legacy", "other"] {
            let url = root.appendingPathComponent("\(name).jsonl")
            try Data("7\n".utf8).write(to: url)
            files[name] = url
        }
        #expect(try scan(store, files["kept"]!, source: "codex-v2") == 7)
        #expect(try scan(store, files["archived"]!, source: "codex-v2") == 7)
        #expect(try scan(store, files["legacy"]!, source: "codex-v1") == 7)
        #expect(try scan(store, files["other"]!, source: "claude-v2") == 7)

        let live = Set([files["kept"]!.resolvingSymlinksInPath().path])
        try store.prune(family: "codex-", source: "codex-v2", keeping: live)

        // 还在的文件命中缓存，不重新读盘
        #expect(try scan(store, files["kept"]!, source: "codex-v2") == 7)
        #expect(store.bytesRead == 0)
        // 被剪掉的两行要重新读盘
        #expect(try scan(store, files["archived"]!, source: "codex-v2") == 7)
        #expect(store.bytesRead > 0)
        #expect(try scan(store, files["legacy"]!, source: "codex-v1") == 7)
        #expect(store.bytesRead > 0)
        // 另一个 Provider 的行不受影响
        #expect(try scan(store, files["other"]!, source: "claude-v2") == 7)
        #expect(store.bytesRead == 0)
    }

    @Test func codexParserRestoresModelAndFractionalTimestampBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("cache.sqlite")
        let file = root.appendingPathComponent("usage.jsonl")
        let first = try UsageScanStore(url: db)
        let context = #"{"type":"turn_context","payload":{"model":"model-a"}}"# + "\n"
        func event(_ n: Int) -> String {
            "{\"timestamp\":\"2026-09-22T10:00:00.123Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(n),\"output_tokens\":1}}}}\n"
        }
        try Data((context + event(100)).utf8).write(to: file)
        _ = try first.scan(url: file, source: "codex", initial: CodexLocalLogParser()) { $0.consume($1) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(event(120).utf8)); try handle.close()
        let restarted = try UsageScanStore(url: db)
        let result = try restarted.scan(url: file, source: "codex", initial: CodexLocalLogParser()) { $0.consume($1) }
        #expect(LocalUsageReport.total(Array(result.rows.values)).total == 121)
        #expect(LocalUsageReport.total(Array(result.rows.values)).records == 2)
        #expect(result.rows.values.first?.model == "model-a")
    }
}
