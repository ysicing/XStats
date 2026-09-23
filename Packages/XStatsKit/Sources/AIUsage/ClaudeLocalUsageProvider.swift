// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CoreFoundation

/// Claude Code 的输入不包含缓存字段；归一化后与 Codex 共用“含缓存输入”的统计口径。
public actor ClaudeLocalUsageProvider: AIUsageProvider {
    /// 解析口径变化时提升版本号；旧命名空间的缓存行会在下一次扫描时被清掉。
    private static let source = "claude-v2"
    public nonisolated let id = AIProviderID.claude
    private let roots: [URL]
    private let databaseURL: URL
    private let now: @Sendable () -> Date
    private var store: UsageScanStore?

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        ScanExecutor.shared.asUnownedSerialExecutor()
    }

    public init(roots: [URL]? = nil, databaseURL: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.databaseURL = databaseURL ?? roots?.first?.appendingPathComponent("usage-cache.sqlite") ?? UsageScanStore.defaultURL
        self.roots = roots ?? Self.defaultRoots()
        self.now = now
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
        let now = self.now()
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
        var scanned: Set<String> = []
        for url in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            do {
                let state = ClaudeLogScanState(calendar: calendar)
                let parsed = try store.scan(url: url, source: Self.source, initial: state) { $0.consume($1) }
                scanned.insert(url.resolvingSymlinksInPath().path)
                for event in parsed.events.values { ClaudeLocalLogParser.merge(event, into: &events) }
            } catch is CancellationError { throw CancellationError() }
            catch { unreadable += 1 }
        }
        // 项目目录被删掉后对应的缓存行不会再出现在扫描结果里，留着只会一直变大。
        if unreadable == 0 { try? store.prune(family: "claude-", source: Self.source, keeping: scanned) }
        var snapshot = AIUsageSnapshot(provider: .claude, fetchedAt: now)
        let rows = events.values.lazy.map(\.row).filter { $0.day >= since }
        snapshot.localUsage = LocalUsageReport(rows: LocalUsageReport.aggregated(rows),
                                               fileCount: files.count, unreadableFiles: unreadable)
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

    static func parse(_ data: Data, calendar: Calendar = .current, iso: ISO8601Parser = ISO8601Parser()) -> Event? {
        guard data.range(of: marker) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "assistant",
              object["isApiErrorMessage"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let id = message["id"] as? String, !id.isEmpty,
              let usage = message["usage"] as? [String: Any],
              let time = iso.date(object["timestamp"]) else { return nil }
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


/// 消息 ID 要跨文件去重，所以整张表都得落到检查点里。
/// 这里不按保留窗口裁剪：检查点会被原样恢复，存进去的截止日期会永远停在首次扫描那天，
/// 于是过期事件反而再也出不去。窗口一律在取数时按当天重新计算。
private struct ClaudeLogScanState: Codable {
    let calendar: Calendar
    var events: [String: ClaudeLocalLogParser.Event] = [:]
    private let iso = ISO8601Parser()

    private enum CodingKeys: String, CodingKey {
        case calendar, events
    }

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    mutating func consume(_ line: Data) {
        guard let event = ClaudeLocalLogParser.parse(line, calendar: calendar, iso: iso) else { return }
        ClaudeLocalLogParser.merge(event, into: &events)
    }
}
