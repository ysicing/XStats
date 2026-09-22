// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CoreFoundation

/// 只读取会话的模型和 Token 元数据，不读取 auth.json，不发送网络请求。
public actor CodexLocalUsageProvider: AIUsageProvider {
    public nonisolated let id = AIProviderID.codex
    private let root: URL
    private let databaseURL: URL
    private var store: UsageScanStore?

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
        var rows: [ModelTokenUsage] = []
        if store == nil { store = try UsageScanStore(url: databaseURL) }
        guard let store else { throw AIUsageFailure.invalidResponse }
        for url in files {
            try Task.checkCancellation()
            do {
                let parser = try store.scan(url: url, source: "codex-v1", initial: CodexLocalLogParser(calendar: calendar)) {
                    $0.consume($1)
                }
                let session = parser.session ?? url.lastPathComponent
                if seen.insert(session).inserted { rows += parser.rows.values.filter { $0.day >= since } }
            } catch is CancellationError { throw CancellationError() }
            catch { unreadable += 1 }
        }
        var snapshot = AIUsageSnapshot(provider: .codex, planName: nil, windows: [], remainingCredits: nil, fetchedAt: now)
        snapshot.localUsage = LocalUsageReport(rows: rows, fileCount: files.count, unreadableFiles: unreadable)
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
    private var created: Date?
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let whole = ISO8601DateFormatter()

    private enum CodingKeys: String, CodingKey {
        case calendar, session, rows, model, previous, sawMeta, replaying, created
    }

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    mutating func consume(_ line: Data) {
        // 大多数日志行是对话/工具正文，跳过 JSON 解码，只处理统计元数据。
        guard Self.markers.contains(where: { line.range(of: $0) != nil }) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any], let type = obj["type"] as? String else { return }
        if type == "session_meta", !sawMeta {
            sawMeta = true; session = payload["id"] as? String
            created = date(obj["timestamp"])
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
        if payload["type"] as? String == "task_started", replaying,
           let started = payload["started_at"] as? Double,
           let baseline = created ?? date(obj["timestamp"]), started >= floor(baseline.timeIntervalSince1970) {
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
        guard let usage, usage.input + usage.output > 0, let timestamp = date(obj["timestamp"]) else { return }
        let day = calendar.startOfDay(for: timestamp)
        let key = "\(day.timeIntervalSince1970):\(model)"
        var row = rows[key] ?? ModelTokenUsage(day: day, model: model)
        row.input += usage.input; row.cached += min(usage.cached, usage.input)
        row.output += usage.output; row.records += 1; rows[key] = row
    }

    private func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
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
