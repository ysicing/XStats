// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CoreFoundation

/// 只读取会话的模型和 Token 元数据，不读取 auth.json，不发送网络请求。
public actor CodexLocalUsageProvider: AIUsageProvider {
    /// 解析口径变化时提升版本号；旧命名空间的缓存行会在下一次扫描时被清掉。
    private static let source = "codex-v2"
    public nonisolated let id = AIProviderID.codex
    private let root: URL
    private let databaseURL: URL
    private var store: UsageScanStore?

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        ScanExecutor.shared.asUnownedSerialExecutor()
    }

    public init(root: URL? = nil, databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? root?.appendingPathComponent("usage-cache.sqlite") ?? UsageScanStore.defaultURL
        self.root = root ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: now))!
        var files: [URL] = []
        var unreadable = 0
        // 活跃目录优先，归档的同一 session ID 只统计一次。
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            var enumerationFailed = false
            let enumerator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return true })
            while let url = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                if url.pathExtension == "jsonl" { files.append(url) }
            }
            if enumerationFailed { unreadable += 1 }
        }
        var seen: Set<String> = []
        var scanned: Set<String> = []
        var rows: [ModelTokenUsage] = []
        if store == nil { store = try UsageScanStore(url: databaseURL) }
        guard let store else { throw AIUsageFailure.invalidResponse }
        for url in files {
            try Task.checkCancellation()
            do {
                let parser = try store.scan(url: url, source: Self.source, initial: CodexLocalLogParser(calendar: calendar)) {
                    $0.consume($1)
                }
                scanned.insert(url.resolvingSymlinksInPath().path)
                let session = parser.session ?? url.lastPathComponent
                if seen.insert(session).inserted { rows += parser.rows.values.filter { $0.day >= since } }
            } catch is CancellationError { throw CancellationError() }
            catch { unreadable += 1 }
        }
        // 归档会改变 rollout 路径，被删掉的会话也不会再出现；只有本轮扫过的文件值得留着缓存。
        if unreadable == 0 { try? store.prune(family: "codex-", source: Self.source, keeping: scanned) }
        var snapshot = AIUsageSnapshot(provider: .codex, fetchedAt: now)
        snapshot.localUsage = LocalUsageReport(rows: LocalUsageReport.aggregated(rows),
                                               fileCount: files.count, unreadableFiles: unreadable)
        return snapshot
    }
}

/// 每个文件独立保留累计基线；重复快照不代表一次新的模型调用。
struct CodexLocalLogParser: Codable {
    private static let markers = ["turn_context", "session_meta", "token_count", "task_started"].map { Data($0.utf8) }
    let calendar: Calendar
    var session: String?
    var rows: [String: ModelTokenUsage] = [:]
    private var model = "unknown"
    private var previous: Counts?
    private var sawMeta = false
    private var replaying = false
    private let iso = ISO8601Parser()

    private enum CodingKeys: String, CodingKey {
        case calendar, session, rows, model, previous, sawMeta, replaying
    }

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    mutating func consume(_ line: Data) {
        // 大多数日志行是对话/工具正文，跳过 JSON 解码，只处理统计元数据。
        guard Self.markers.contains(where: { line.range(of: $0) != nil }) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any], let type = obj["type"] as? String else { return }
        if type == "session_meta", !sawMeta {
            sawMeta = true; session = payload["id"] as? String
            let source = payload["source"] as? [String: Any]
            replaying = [payload["forked_from_id"], payload["parent_thread_id"], source?["subagent"]]
                .contains { value in
                    guard let value, !(value is NSNull) else { return false }
                    return (value as? String)?.isEmpty != true
                } || payload["thread_source"] as? String == "subagent"
            return
        }
        if type == "turn_context" {
            model = modelName(payload) ?? model; return
        }
        guard type == "event_msg" else { return }
        // 回放进来的父级累计快照总是排在首个 task_started 之前，所以第一次开工就结束回放。
        // 不能拿 started_at 和会话创建时间比：子代理的 started_at 是父级回合的开始时间，
        // 天然早于子会话文件；新版 Codex 更是完全不发这个字段。
        if payload["type"] as? String == "task_started" {
            replaying = false; return
        }
        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else { return }
        let total = (info["total_token_usage"] as? [String: Any]).flatMap(Counts.init)
        let last = (info["last_token_usage"] as? [String: Any]).flatMap(Counts.init)
        model = modelName(payload) ?? modelName(info) ?? model
        if replaying { if let total { previous = total }; return }
        if let total, total == previous { return }
        let usage = last ?? total.map { $0.delta(previous) }
        if let total { previous = total }
        guard let usage, usage.input + usage.output > 0, let timestamp = iso.date(obj["timestamp"]) else { return }
        let day = calendar.startOfDay(for: timestamp)
        let key = "\(day.timeIntervalSince1970):\(model)"
        var row = rows[key] ?? ModelTokenUsage(day: day, model: model)
        row.input += usage.input; row.cached += min(usage.cached, usage.input)
        row.output += usage.output; row.records += 1; rows[key] = row
    }

    private func modelName(_ object: [String: Any]) -> String? {
        let metadata = object["metadata"] as? [String: Any]
        return [object["model"], object["model_name"], metadata?["model"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private struct Counts: Equatable, Codable {
        let input: Int
        let cached: Int
        let output: Int
        init?(_ json: [String: Any]) {
            func number(_ keys: [String]) -> Int? {
                for key in keys {
                    if let n = json[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                       n.doubleValue >= 0, n.doubleValue < 1e15 { return n.intValue }
                }
                return nil
            }
            let input = number(["input_tokens", "prompt_tokens"])
            let output = number(["output_tokens", "completion_tokens"])
            guard input != nil || output != nil else { return nil }
            self.input = input ?? 0; self.output = output ?? 0
            cached = number(["cached_input_tokens", "cache_read_input_tokens"]) ?? 0
        }
        private init(input: Int, cached: Int, output: Int) {
            self.input = input; self.cached = cached; self.output = output
        }
        func delta(_ prior: Self?) -> Self {
            Self(input: max(0, input - (prior?.input ?? 0)), cached: max(0, cached - (prior?.cached ?? 0)),
                 output: max(0, output - (prior?.output ?? 0)))
        }
    }
}
