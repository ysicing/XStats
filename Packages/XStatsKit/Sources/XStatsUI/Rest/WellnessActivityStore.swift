// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SQLite3

/// 只记录用户启动的计时和主动饮水确认；actor 上执行有界 SQLite I/O，不写入设置备份。
actor WellnessActivityStore {
    enum Failure: Error { case database, invalidActivity }
    static let retention: TimeInterval = 90 * 86400
    private static let maximumRecords = 20_000
    private let url: URL?
    // 仅 actor 方法访问；析构时已无在途 actor 调用，关闭 SQLite 句柄。
    nonisolated(unsafe) private var db: OpaquePointer?

    init(url: URL?) { self.url = url }
    deinit { if let db { sqlite3_close(db) } }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XStats/wellness.sqlite")
    }

    func record(_ activity: WellnessActivity, now: Date) throws {
        guard activity.startedAt.timeIntervalSince1970.isFinite, activity.endedAt.timeIntervalSince1970.isFinite,
              activity.endedAt >= activity.startedAt else { throw Failure.invalidActivity }
        try statement("INSERT OR IGNORE INTO activity(id,kind,start,end,completed,part_of_rest) VALUES(?,?,?,?,?,?)") { query in
            bind(activity.id.uuidString, at: 1, in: query)
            bind(activity.kind.rawValue, at: 2, in: query)
            sqlite3_bind_double(query, 3, activity.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(query, 4, activity.endedAt.timeIntervalSince1970)
            sqlite3_bind_int(query, 5, activity.completed ? 1 : 0)
            sqlite3_bind_int(query, 6, activity.isPartOfRest ? 1 : 0)
            guard sqlite3_step(query) == SQLITE_DONE else { throw Failure.database }
        }
        try prune(at: now)
    }

    private func prune(at now: Date) throws {
        try statement("DELETE FROM activity WHERE end < ?") { query in
            sqlite3_bind_double(query, 1, now.timeIntervalSince1970 - Self.retention)
            guard sqlite3_step(query) == SQLITE_DONE else { throw Failure.database }
        }
        try statement("DELETE FROM activity WHERE id IN (SELECT id FROM activity ORDER BY end DESC LIMIT -1 OFFSET ?)") { query in
            sqlite3_bind_int(query, 1, Int32(Self.maximumRecords))
            guard sqlite3_step(query) == SQLITE_DONE else { throw Failure.database }
        }
    }

    func activities(since date: Date, now: Date? = nil) throws -> [WellnessActivity] {
        if let now { try prune(at: now) }
        return try statement("SELECT id,kind,start,end,completed,part_of_rest FROM activity WHERE end >= ? ORDER BY start,id") { query in
            sqlite3_bind_double(query, 1, date.timeIntervalSince1970)
            var result: [WellnessActivity] = []
            var status = sqlite3_step(query)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                if let rawID = sqlite3_column_text(query, 0), let rawKind = sqlite3_column_text(query, 1),
                   let id = UUID(uuidString: String(cString: rawID)),
                   let kind = WellnessActivityKind(rawValue: String(cString: rawKind)) {
                    let activity = WellnessActivity(id: id, kind: kind,
                        startedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 2)),
                        endedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 3)),
                        completed: sqlite3_column_int(query, 4) != 0,
                        isPartOfRest: sqlite3_column_int(query, 5) != 0)
                    result.append(activity)
                }
                status = sqlite3_step(query)
            }
            guard status == SQLITE_DONE else { throw Failure.database }
            return result
        }
    }

    func remove(_ id: UUID) throws {
        try statement("DELETE FROM activity WHERE id = ?") { query in
            bind(id.uuidString, at: 1, in: query)
            guard sqlite3_step(query) == SQLITE_DONE else { throw Failure.database }
        }
    }

    func revokeLatestFocusCompletion(since date: Date) throws {
        try statement("UPDATE activity SET completed=0 WHERE id=(SELECT id FROM activity WHERE kind='focus' AND completed=1 AND end >= ? ORDER BY end DESC LIMIT 1)") { query in
            sqlite3_bind_double(query, 1, date.timeIntervalSince1970)
            guard sqlite3_step(query) == SQLITE_DONE else { throw Failure.database }
        }
    }

    func clear() throws {
        try statement("DELETE FROM activity") { query in
            guard sqlite3_step(query) == SQLITE_DONE else { throw Failure.database }
        }
    }

    private func open() throws -> OpaquePointer {
        if let db { return db }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        var handle: OpaquePointer?
        let path = url?.path ?? ":memory:"
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw Failure.database
        }
        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS activity(
          id TEXT PRIMARY KEY, kind TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
          completed INTEGER NOT NULL, part_of_rest INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS activity_end ON activity(end);
        """
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw Failure.database
        }
        sqlite3_busy_timeout(handle, 1000)
        db = handle
        return handle
    }

    private func statement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        let db = try open()
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else { throw Failure.database }
        defer { sqlite3_finalize(query) }
        return try body(query)
    }

    private func bind(_ value: String, at index: Int32, in query: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString { sqlite3_bind_text(query, index, $0, -1, transient) }
    }
}
