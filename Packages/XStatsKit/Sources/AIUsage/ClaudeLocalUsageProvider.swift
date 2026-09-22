// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CoreFoundation

/// Claude Code 的输入不包含缓存字段；归一化后与 Codex 共用“含缓存输入”的统计口径。
public actor ClaudeLocalUsageProvider: AIUsageProvider {
    public nonisolated let id = AIProviderID.claude
    private let roots: [URL]
    private let databaseURL: URL
    private var store: UsageScanStore?

    public init(roots: [URL]? = nil, databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? roots?.first?.appendingPathComponent("usage-cache.sqlite") ?? UsageScanStore.defaultURL
        self.roots = roots ?? Self.defaultRoots()
    }

    public static func defaultRoots(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        if let override = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return [URL(fileURLWithPath: (override as NSString).expandingTildeInPath)]
        }
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        return [home.appendingPathComponent(".claude"), xdg.appendingPathComponent("claude")]
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: now))!
        var files: Set<URL> = []
        var unreadable = 0
        for root in roots {
            let directory = (root.lastPathComponent == "projects" ? root : root.appendingPathComponent("projects"))
                .resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            var enumerationFailed = false
            let enumerator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return true })
            while let url = enumerator?.nextObject() as? URL {
                try Task.checkCancellation()
                if url.pathExtension == "jsonl" { files.insert(url) }
            }
            if enumerationFailed { unreadable += 1 }
        }
        if store == nil { store = try UsageScanStore(url: databaseURL) }
        guard let store else { throw AIUsageFailure.invalidResponse }
        var events: [String: ClaudeLocalLogParser.Event] = [:]
        for url in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            do {
                let parsed = try store.scan(url: url, source: "claude-v1", initial: ClaudeLogScanState(calendar: calendar)) {
                    $0.consume($1)
                }
                for event in parsed.events.values { ClaudeLocalLogParser.merge(event, into: &events) }
            } catch is CancellationError { throw CancellationError() }
            catch { unreadable += 1 }
        }
        var rows: [String: ModelTokenUsage] = [:]
        for event in events.values where event.row.day >= since {
            var row = rows[event.row.id] ?? ModelTokenUsage(day: event.row.day, model: event.row.model)
            row.add(event.row); rows[row.id] = row
        }
        var snapshot = AIUsageSnapshot(provider: .claude, planName: nil, windows: [], remainingCredits: nil, fetchedAt: now)
        snapshot.localUsage = LocalUsageReport(rows: Array(rows.values), fileCount: files.count, unreadableFiles: unreadable)
        return snapshot
    }
}

enum ClaudeLocalLogParser {
    struct Event: Sendable, Codable {
        let id: String
        let row: ModelTokenUsage
        let final: Bool
        let timestamp: Date
    }
    private static let marker = Data("\"usage\"".utf8)

    static func parse(_ data: Data, calendar: Calendar = .current) -> Event? {
        guard data.range(of: marker) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "assistant",
              object["isApiErrorMessage"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let id = message["id"] as? String, !id.isEmpty,
              let usage = message["usage"] as? [String: Any],
              let rawTime = object["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let time = formatter.date(from: rawTime) ?? ISO8601DateFormatter().date(from: rawTime) else { return nil }
        func count(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue >= 0, n.doubleValue < 1e15 else { return nil }
            return n.intValue
        }
        let input = count(usage["input_tokens"]) ?? 0
        let output = count(usage["output_tokens"]) ?? 0
        let read = count(usage["cache_read_input_tokens"]) ?? 0
        let breakdown = usage["cache_creation"] as? [String: Any]
        let created = count(usage["cache_creation_input_tokens"])
            ?? ((count(breakdown?["ephemeral_5m_input_tokens"]) ?? 0) + (count(breakdown?["ephemeral_1h_input_tokens"]) ?? 0))
        guard input + output + read + created > 0 else { return nil }
        let rawModel = (message["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawModel != "<synthetic>" else { return nil }
        let model = rawModel.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let row = ModelTokenUsage(day: calendar.startOfDay(for: time), model: model,
                                  input: input + read + created, cached: read, output: output, records: 1, cacheCreated: created)
        return Event(id: id, row: row, final: message["stop_reason"] is String, timestamp: time)
    }

    static func merge(_ event: Event, into events: inout [String: Event]) {
        if let prior = events[event.id] {
            if prior.final && !event.final { return }
            if prior.final == event.final {
                if prior.row.output > event.row.output { return }
                if prior.row.output == event.row.output && prior.timestamp > event.timestamp { return }
            }
        }
        events[event.id] = event
    }
}


private struct ClaudeLogScanState: Codable {
    let calendar: Calendar
    var events: [String: ClaudeLocalLogParser.Event] = [:]

    mutating func consume(_ line: Data) {
        if let event = ClaudeLocalLogParser.parse(line, calendar: calendar) {
            ClaudeLocalLogParser.merge(event, into: &events)
        }
    }
}
