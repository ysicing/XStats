// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CryptoKit
import SQLite3

/// 每个 Provider actor 独占一个连接。游标与解析状态在同一 SQLite 行中原子提交。
/// 状态只包含计数/模型/消息 ID，不持久化日志正文或未完成行的内容。
final class UsageScanStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XStats/ai-usage.sqlite")
    }
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var bytesRead = 0

    private struct Checkpoint<State: Codable>: Codable {
        let size: UInt64
        let modified: Date
        let inode: UInt64
        let timeZone: String
        let offset: UInt64
        let prefixHash: Data
        let boundaryHash: Data
        let state: State
        let preview: State
    }

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle); throw AIUsageFailure.invalidResponse
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        guard sqlite3_exec(handle, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS usage_scan_v1 (
                source TEXT NOT NULL, path TEXT NOT NULL, payload BLOB NOT NULL,
                PRIMARY KEY(source, path)
            );
            """, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle); db = nil; throw AIUsageFailure.invalidResponse
        }
    }
    deinit { sqlite3_close(db) }

    func scan<State: Codable>(url: URL, source: String, initial: State,
                              consume: (inout State, Data) -> Void) throws -> State {
        bytesRead = 0
        let path = url.resolvingSymlinksInPath().path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let zone = Calendar.current.timeZone.identifier
        let old = try load(source: source, path: path).flatMap { try? JSONDecoder().decode(Checkpoint<State>.self, from: $0) }
        if let old, old.size == size, old.modified == modified, old.inode == inode, old.timeZone == zone {
            return old.preview
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        func hash(_ start: UInt64, _ length: Int) throws -> Data {
            try file.seek(toOffset: start)
            let data = try file.read(upToCount: length) ?? Data()
            bytesRead += data.count
            return Data(SHA256.hash(data: data))
        }
        var offset: UInt64 = 0
        var state = initial
        // 只对正常追加复用基线。替换、截断、时区变更或边界内容改变时重建该文件。
        if let old, size > old.size, inode == old.inode, old.timeZone == zone,
           try hash(0, Int(min(4096, old.offset))) == old.prefixHash,
           try hash(old.offset - min(4096, old.offset), Int(min(4096, old.offset))) == old.boundaryHash {
            offset = old.offset; state = old.state
        }
        try file.seek(toOffset: offset)
        var pending = Data()
        var cursor = offset
        var skipping = false
        while cursor < size {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: Int(min(128 * 1024, size - cursor))) ?? Data()
            guard !chunk.isEmpty else { throw AIUsageFailure.invalidResponse }
            bytesRead += chunk.count; cursor += UInt64(chunk.count)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                if !skipping { consume(&state, Data(pending[..<newline])) }
                let length = pending.distance(from: pending.startIndex, to: newline) + 1
                offset += UInt64(length)
                pending.removeSubrange(...newline); skipping = false
            }
            if pending.count > 8 * 1024 * 1024 {
                // 跳过超长正文，直到遇到换行才允许提交游标。
                offset += UInt64(pending.count); pending.removeAll(); skipping = true
            }
        }
        var preview = state
        if !skipping && !pending.isEmpty { consume(&preview, pending) }
        // 超长且尚未结束的行不提交，下一次仍从上一个检查点重试。
        if skipping { return preview }
        let prefix = try hash(0, Int(min(4096, offset)))
        let boundary = try hash(offset - min(4096, offset), Int(min(4096, offset)))
        let checkpoint = Checkpoint(size: size, modified: modified, inode: inode, timeZone: zone, offset: offset,
            prefixHash: prefix, boundaryHash: boundary, state: state, preview: preview)
        try Task.checkCancellation()
        try save(try JSONEncoder().encode(checkpoint), source: source, path: path)
        return preview
    }

    private func statement(_ sql: String, source: String, path: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AIUsageFailure.invalidResponse
        }
        sqlite3_bind_text(statement, 1, source, -1, transient)
        sqlite3_bind_text(statement, 2, path, -1, transient)
        return statement
    }

    private func load(source: String, path: String) throws -> Data? {
        let s = try statement("SELECT payload FROM usage_scan_v1 WHERE source=? AND path=?", source: source, path: path)
        defer { sqlite3_finalize(s) }
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(s, 0) else { throw AIUsageFailure.invalidResponse }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0)))
    }

    private func save(_ data: Data, source: String, path: String) throws {
        let s = try statement("INSERT OR REPLACE INTO usage_scan_v1 (source,path,payload) VALUES (?,?,?)", source: source, path: path)
        defer { sqlite3_finalize(s) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 3, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw AIUsageFailure.invalidResponse }
    }
}
