// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import SQLite3

enum LaunchpadImport {
  private final class QueryBudget {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var steps = 0
  }
  struct Row: Sendable {
    var id: Int64
    var type: Int32
    var parent: Int64
    var order: Int64
    var uuid: String
    var bundleID: String
    var name: String
  }

  static func systemLayout(applications: [AppCommand]) throws -> LaunchpadLayout? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
    guard length > 0, length <= buffer.count else { return nil }
    let directory = String(
      decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return try read(
      URL(fileURLWithPath: directory).appendingPathComponent("com.apple.dock.launchpad/db/db"),
      applications: applications)
  }

  /// 在临时副本上处理 WAL；既不使用会忽略 WAL 的 immutable，也不让 SQLite 写系统库的共享内存。
  static func read(_ source: URL, applications: [AppCommand]) throws -> LaunchpadLayout? {
    let manager = FileManager.default
    guard manager.fileExists(atPath: source.path) else { return nil }
    let temporary = manager.temporaryDirectory.appendingPathComponent("XStats-Launchpad-\(UUID())")
    try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temporary) }
    let copy = temporary.appendingPathComponent("db")
    var snapshots: [(URL, UInt64, Date)] = []
    var bytes: UInt64 = 0
    for suffix in ["-wal", "-shm", ""] {
      try Task.checkCancellation()
      let file = URL(fileURLWithPath: source.path + suffix)
      guard manager.fileExists(atPath: file.path) else { continue }
      let attributes = try manager.attributesOfItem(atPath: file.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        let size = attributes[.size] as? UInt64,
        let modified = attributes[.modificationDate] as? Date,
        size <= 64_000_000, bytes <= 64_000_000 - size
      else { return nil }
      bytes += size
      snapshots.append((file, size, modified))
      let destination = URL(fileURLWithPath: copy.path + suffix)
      try manager.copyItem(at: file, to: destination)
      guard
        try manager.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
          == .typeRegular
      else { return nil }
    }
    for (file, size, modified) in snapshots {
      let attributes = try manager.attributesOfItem(atPath: file.path)
      guard attributes[.size] as? UInt64 == size,
        attributes[.modificationDate] as? Date == modified
      else { return nil }
    }
    var database: OpaquePointer?
    guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      sqlite3_close(database)
      return nil
    }
    defer { sqlite3_close(database) }
    let budget = QueryBudget()
    sqlite3_progress_handler(
      database, 1000,
      { context in
        guard let context else { return 1 }
        let budget = Unmanaged<QueryBudget>.fromOpaque(context).takeUnretainedValue()
        budget.steps += 1
        return Task.isCancelled || budget.steps > 2000 || ContinuousClock.now > budget.deadline
          ? 1 : 0
      }, Unmanaged.passUnretained(budget).toOpaque())
    defer {
      sqlite3_progress_handler(database, 0, nil, nil)
      withExtendedLifetime(budget) {}
    }
    sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 1_000_000)
    var statement: OpaquePointer?
    let sql = """
      SELECT i.rowid,i.type,i.parent_id,i.ordering,i.uuid,a.bundleid,coalesce(g.title,a.title,'')
      FROM items i LEFT JOIN apps a ON a.item_id=i.rowid
      LEFT JOIN groups g ON g.item_id=i.rowid LIMIT 10001
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    var rows: [Row] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      try Task.checkCancellation()
      guard rows.count < 10_000 else { return nil }
      rows.append(
        Row(
          id: sqlite3_column_int64(statement, 0), type: sqlite3_column_int(statement, 1),
          parent: sqlite3_column_int64(statement, 2), order: sqlite3_column_int64(statement, 3),
          uuid: string(statement, column: 4), bundleID: string(statement, column: 5),
          name: string(statement, column: 6)))
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { return nil }
    var identifiers: [String: String] = [:]
    for command in applications {
      try Task.checkCancellation()
      guard case .openApplication(let url) = command.action,
        let bundleID = Bundle(url: url)?.bundleIdentifier
      else { continue }
      if identifiers[bundleID] == nil { identifiers[bundleID] = command.id }
    }
    return layout(rows: rows, identifiers: identifiers)
  }

  static func layout(rows: [Row], identifiers: [String: String]) -> LaunchpadLayout? {
    let children = Dictionary(
      grouping: rows.sorted { ($0.order, $0.id) < ($1.order, $1.id) }, by: \.parent)
    guard let root = rows.first(where: { $0.type == 1 && $0.uuid == "ROOTPAGE" }) else {
      return nil
    }
    var pages: [[LaunchpadLayout.Item]] = []
    for page in children[root.id, default: []] where page.type == 3 {
      var entries: [LaunchpadLayout.Item] = []
      for row in children[page.id, default: []] {
        if row.type == 4, let id = identifiers[row.bundleID] {
          entries.append(.app(id))
        } else if row.type == 2 {
          let descendants = children[row.id, default: []].flatMap {
            $0.type == 3 ? children[$0.id, default: []] : [$0]
          }
          let apps = descendants.filter { $0.type == 4 }.compactMap { identifiers[$0.bundleID] }
          if !apps.isEmpty {
            entries.append(.init(id: "folder.import.\(row.id)", name: row.name, apps: apps))
          }
        }
      }
      if !entries.isEmpty { pages.append(entries) }
    }
    return pages.isEmpty ? nil : LaunchpadLayout(pages: pages)
  }

  private static func string(_ statement: OpaquePointer?, column: Int32) -> String {
    guard let value = sqlite3_column_text(statement, column),
      sqlite3_column_bytes(statement, column) <= 4096
    else { return "" }
    return String(cString: value)
  }
}
