// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SQLite3

/// 只保存每个来源最后一次成功的额度快照，不包含登录凭据或请求内容。
public final class AIQuotaCacheStore {
    public static var defaultURL: URL { UsageScanStore.defaultURL }

    private enum StoreError: Error { case sqlite, invalidSnapshot }
    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            sqlite3_close(connection)
            throw StoreError.sqlite
        }
        sqlite3_busy_timeout(connection, 5_000)
        guard sqlite3_exec(connection, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS ai_quota_cache_v1 (
                provider TEXT PRIMARY KEY, payload BLOB NOT NULL
            );
            """, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw StoreError.sqlite
        }
        db = connection
    }

    deinit { sqlite3_close(db) }

    public func load() throws -> [AIProviderID: AIQuotaSnapshot] {
        let query = try statement("SELECT provider,payload FROM ai_quota_cache_v1")
        defer { sqlite3_finalize(query) }
        var snapshots: [AIProviderID: AIQuotaSnapshot] = [:]
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            if let rawProvider = sqlite3_column_text(query, 0),
               let provider = AIProviderID(rawValue: String(cString: rawProvider)),
               let bytes = sqlite3_column_blob(query, 1),
               let snapshot = try? JSONDecoder().decode(AIQuotaSnapshot.self,
                   from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 1)))),
               snapshot.provider == provider, Self.isValid(snapshot) {
                snapshots[provider] = snapshot
            }
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw StoreError.sqlite }
        return snapshots
    }

    public func save(_ snapshot: AIQuotaSnapshot) throws {
        guard Self.isValid(snapshot) else { throw StoreError.invalidSnapshot }
        let data = try JSONEncoder().encode(snapshot)
        let query = try statement("INSERT OR REPLACE INTO ai_quota_cache_v1(provider,payload) VALUES (?,?)")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, snapshot.provider.rawValue, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(query, 2, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw StoreError.sqlite }
    }

    public func clear(_ provider: AIProviderID) throws {
        let query = try statement("DELETE FROM ai_quota_cache_v1 WHERE provider=?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, provider.rawValue, -1, transient)
        guard sqlite3_step(query) == SQLITE_DONE else { throw StoreError.sqlite }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else {
            throw StoreError.sqlite
        }
        return query
    }

    private static func isValid(_ snapshot: AIQuotaSnapshot) -> Bool {
        !snapshot.windows.isEmpty && snapshot.windows.allSatisfy {
            $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
        }
    }
}
