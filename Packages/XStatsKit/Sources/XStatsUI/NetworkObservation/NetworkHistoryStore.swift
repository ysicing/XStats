// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Localization
import NetworkObservation
import OSLog
import SQLite3

struct NetworkHistoryFilter: Hashable, Sendable {
  var grouping: String = "apps"
  var selection: String? = nil
  var search: String = ""
  var interval: TimeInterval = 900
  var end: Date? = nil
  var expandedRegions: Set<String> = []
}

struct NetworkHistoryGroup: Identifiable, Sendable {
  let id: String
  let name: String
  let applicationPath: String?
  let processID: Int32?
  let count: Int
  var hasChildren = false
}

struct NetworkHistoryView: Sendable {
  let records: [ObservedConnection]
  let total: Int
  let groups: [NetworkHistoryGroup]
  let points: [NetworkTrafficPoint]
  /// 仅返回当前页的归属；待查询地址通过 pendingAddresses 分批读取。
  let countries: [String: String]
  var locations: [String: NetworkIPLocation] = [:]
  var regions: [NetworkHistoryRegion] = []
}

struct NetworkHistoryRegion: Sendable {
  let key: String
  let count: Int
  let latest: Date
}

/// 元数据和累计基线留在数据库；展示上限不参与历史淘汰，整个批次与游标共同提交。
/// 过期清理仅在 ingest/view 访问时惰性执行；停用或退出后不运行后台清理任务。
actor NetworkHistoryStore {
  enum Failure: LocalizedError, Equatable {
    case database(Int32)
    case storageBudgetExceeded
    case invalidData
    case unsupportedSchema

    var errorDescription: String? {
      switch self {
      case .unsupportedSchema:
        tr("网络历史数据库版本不兼容")
      case .database(SQLITE_FULL), .storageBudgetExceeded:
        tr("网络历史超过磁盘安全预算，请清空记录或释放空间后重试")
      case .database(_), .invalidData:
        tr("无法保存网络历史，请检查磁盘空间后重试")
      }
    }
  }

  struct Diagnostics: Sendable {
    let connectionRows: Int
    let trafficRows: Int
    let trafficTotalRows: Int
    let cursorRows: Int
    let pageCount: Int
    let pageSize: Int
    let databaseBytes: Int
    let databaseFileBytes: Int
    let walBytes: Int
    let storageBytes: Int
    let cacheBytes: Int
    let preparedStatementCount: Int
    let discarded: Int64
    let captureDropped: Int64
  }

  static let retention: TimeInterval = 900
  static let maximumDatabaseBytes = 256 * 1024 * 1024
  static let maximumWALBytes = 64 * 1024 * 1024
  static let maximumStorageBytes = maximumDatabaseBytes + maximumWALBytes
  static var defaultURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("XStats/network-history.sqlite")
  }

  /// 句柄没有离开 actor；包装对象负责析构，避免 actor 析构器跨隔离访问 C 指针。
  private final class Database {
    let handle: OpaquePointer
    var statements: [String: OpaquePointer] = [:]

    init(_ handle: OpaquePointer) { self.handle = handle }

    deinit {
      for statement in statements.values { sqlite3_finalize(statement) }
      sqlite3_close_v2(handle)
    }
  }

  private struct State {
    let session: String
    let epoch: String
    let owner: String
    let startedAt: Double
    let segment: Int64
  }

  private struct Baseline {
    let received: UInt64?
    let sent: UInt64?
    let timestamp: Double?
    let session: String?
    let owner: String?
    let segment: Int64
    let closed: Bool
  }

  private enum Value {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
  }

  private struct FileSizes {
    let database: Int
    let wal: Int
    var total: Int { database + wal }
  }

  private struct IngestKey: Equatable {
    let epoch: String
    let session: UUID
    let startedAt: Double
    let cursor: Int64
    let discarded: Int64
    let captureDropped: Int64
    let protocolVersion: Int
    let trafficVersion: Int?
  }

  private static let log = Logger(subsystem: "work.12306.xstats", category: "network-history")
  private let url: URL?
  private let walBudgetBytes: Int
  private var database: Database?
  private var owner = UUID().uuidString
  private var nextPruneAt = -Double.infinity
  private var pruneHasMore = false
  private var nextCheckpointAt = -Double.infinity
  private var lastError: Int32?
  private var committedIngest: (key: IngestKey, observedAt: Double)?

  /// nil 使用内存库；测试可下调 WAL 预算，不能放宽生产上限。初始化不执行文件 I/O。
  init(url: URL? = nil, walBudgetBytes: Int = NetworkHistoryStore.maximumWALBytes) {
    precondition(walBudgetBytes > 0 && walBudgetBytes <= NetworkHistoryStore.maximumWALBytes)
    self.url = url
    self.walBudgetBytes = walBudgetBytes
  }

  func ingest(
    _ batch: ObservationBatch, session: UUID, sessionStartedAt: Date, observedAt: Date = Date()
  ) throws {
    let now = observedAt.timeIntervalSince1970
    let startedAt = sessionStartedAt.timeIntervalSince1970
    guard now.isFinite, startedAt.isFinite, abs(now) < 1e12, abs(startedAt) < 1e12,
      batch.cursor >= 0, batch.discarded >= 0
    else {
      throw Failure.invalidData
    }
    let key = IngestKey(
      epoch: batch.epoch, session: session, startedAt: startedAt, cursor: batch.cursor,
      discarded: batch.discarded, captureDropped: batch.captureDropped ?? 0,
      protocolVersion: batch.protocolVersion, trafficVersion: batch.trafficVersion)
    if batch.protocolVersion >= 3, batch.events.isEmpty, batch.traffic?.isEmpty ?? true,
      batch.activeIDs == nil, let committedIngest, committedIngest.key == key,
      now >= committedIngest.observedAt, now < committedIngest.observedAt + 15,
      now < nextPruneAt, now < nextCheckpointAt
    {
      // 只跳过已经持久化的同一游标；新会话、丢失计数变化和维护到期都必须进事务。
      return
    }
    let didPrune = now >= nextPruneAt
    try transaction {
      let state = try observationState(
        session: session.uuidString, epoch: batch.epoch, startedAt: startedAt, now: now)
      let previousSequence = try scalar(
        "SELECT sequence FROM cursors WHERE epoch=?", [.text(batch.epoch)])
      let clearBefore = try rows("SELECT clear_before FROM settings WHERE singleton=1") {
        sqlite3_column_double($0, 0)
      }.first
      // 排序只涉及这一批事件，不读取全库；同序列回放由持久游标拦截。
      for record in batch.events.sorted(by: { $0.sequence < $1.sequence }) {
        try Task.checkCancellation()
        guard record.sequence > previousSequence else { continue }
        try validate(record, cursor: batch.cursor)
        let evidence = record.traffic?.timestamp ?? record.closedAt ?? record.timestamp
        // 清空后的迟到批次仍可推进 ACK，但不能把清空前的数据重新插回历史。
        if let clearBefore, evidence.timeIntervalSince1970 <= clearBefore { continue }
        try save(record, epoch: batch.epoch, state: state)
        if let snapshot = record.traffic {
          try sample(snapshot, epoch: batch.epoch, state: state, allowsClosed: true)
        } else if record.closedAt == nil {
          // 没有快照的旧版 open 也能给下一批 close 提供零基线；旧会话回放不建立基线。
          try establishOpeningBaseline(record, epoch: batch.epoch, state: state)
        }
        if record.closedAt != nil {
          try execute(
            """
            UPDATE connections SET base_rx=NULL,base_tx=NULL,base_at=NULL,
              base_session=NULL,base_owner=NULL WHERE epoch=? AND id=?
            """, [.text(batch.epoch), .text(record.id.uuidString)])
        }
      }
      // v3 不提供全量活动快照。旧版名单只控制活动展示，不清除基线，避免漏算下一批 close。
      if batch.protocolVersion < 3, let activeIDs = batch.activeIDs {
        try execute(
          "UPDATE connections SET live_session=NULL WHERE epoch=? AND live_session=?",
          [.text(batch.epoch), .text(state.session)])
        for id in activeIDs {
          try execute(
            """
            UPDATE connections SET live_session=?,live_owner=?,retired_at=NULL,last_seen=MAX(last_seen,?)
            WHERE epoch=? AND id=? AND closed_at IS NULL
            """,
            [
              .text(state.session), .text(owner), .real(now), .text(batch.epoch),
              .text(id.uuidString),
            ])
        }
      }
      for snapshot in batch.traffic ?? [] {
        try Task.checkCancellation()
        // 元数据查自数据库，既不依赖 controller 的 512 条缓存，也不把未知快照当新连接。
        try sample(snapshot, epoch: batch.epoch, state: state, allowsClosed: false)
      }
      // 丢失信息与可用事件一起保存；是否停采集由 controller 决定。
      try execute(
        """
        INSERT INTO cursors(epoch,sequence,discarded,capture_dropped,touched) VALUES(?,?,?,?,?)
        ON CONFLICT(epoch) DO UPDATE SET sequence=MAX(sequence,excluded.sequence),
          discarded=MAX(discarded,excluded.discarded),
          capture_dropped=MAX(capture_dropped,excluded.capture_dropped),touched=excluded.touched
        """,
        [
          .text(batch.epoch), .integer(batch.cursor), .integer(batch.discarded),
          .integer(max(0, batch.captureDropped ?? 0)), .real(now),
        ])
      if didPrune { try prune(now: now) }
    }
    if didPrune { nextPruneAt = now + (pruneHasMore ? 0 : 15) }
    try checkpointIfNeeded(now: now)
    committedIngest = (key, now)
  }

  func view(
    filter: NetworkHistoryFilter, activeOnly: Bool, offset: Int, now: Date = Date()
  ) throws -> NetworkHistoryView {
    let seconds = now.timeIntervalSince1970
    guard seconds.isFinite, abs(seconds) < 1e12 else { throw Failure.invalidData }
    let end = min(seconds, filter.end?.timeIntervalSince1970 ?? seconds)
    guard end.isFinite, filter.interval.isFinite, filter.interval > 0 else {
      throw Failure.invalidData
    }
    let interval = min(Self.retention, filter.interval)
    // 活动连接列表沿用保留窗口；一分钟仅限定实时曲线，不能丢掉较早建立的活动流。
    let start = max(seconds - Self.retention, end - (activeOnly ? Self.retention : interval))
    let didPrune = seconds >= nextPruneAt
    let result = try transaction {
      if didPrune { try prune(now: seconds) }
      let group = groupExpression(filter.grouping)
      let base: [Value] = [
        .real(start), .text(filter.search),
        filter.selection.map(Value.text) ?? .null, .text(owner), .integer(activeOnly ? 1 : 0),
        .real(end),
      ]
      let matching = """
        ?1<=?6 AND c.last_seen>=?1 AND COALESCE(c.closed_at,c.retired_at,?1)>=?1
        AND c.opened_at<=?6 AND \(Self.searchPredicate)
        """
      let active = """
        c.closed_at IS NULL AND c.retired_at IS NULL AND c.live_owner=?4
        AND c.live_session=(SELECT session FROM state WHERE singleton=1)
        AND c.epoch=(SELECT epoch FROM state WHERE singleton=1)
        """
      let selected =
        filter.grouping == "country"
        ? "(?3 IS NULL OR \(group.key)=?3 OR ((?3='CN' OR SUBSTR(?3,1,3)='CN|') AND SUBSTR(\(group.key),1,LENGTH(?3)+1)=?3||'|'))"
        : "(?3 IS NULL OR \(group.key)=?3)"
      let pagePredicate = """
        \(matching) AND \(selected) AND (?5=0 OR (\(active)))
        """
      let total = Int(
        try scalar(
          "SELECT COUNT(*) FROM connections c LEFT JOIN geography g ON g.address=c.address WHERE \(pagePredicate)",
          base))
      // offset 来自界面但仍钳制在合法范围；超出总数返回空页，不回绕到第一页。
      let pageOffset = min(max(0, offset), total)
      let page = try rows(
        """
        SELECT c.id,c.sequence,c.opened_at,c.closed_at,c.pid,c.path,c.address,c.hostname,
          c.port,c.transport,c.direction,c.last_rx,c.last_tx,c.last_at,c.country,g.location
        FROM connections c LEFT JOIN geography g ON g.address=c.address WHERE \(pagePredicate)
        ORDER BY c.opened_at DESC,c.id,c.epoch LIMIT 200 OFFSET ?7
        """, base + [.integer(Int64(pageOffset))]
      ) { query -> (ObservedConnection, String?, NetworkIPLocation?) in
        guard let id = UUID(uuidString: text(query, 0) ?? ""),
          let transport = ConnectionTransport(rawValue: text(query, 9) ?? ""),
          let direction = ConnectionDirection(rawValue: text(query, 10) ?? "")
        else { throw Failure.invalidData }
        var record = ObservedConnection(
          id: id, timestamp: Date(timeIntervalSince1970: sqlite3_column_double(query, 2)),
          processID: sqlite3_column_int(query, 4), executablePath: text(query, 5) ?? "",
          address: text(query, 6), hostname: text(query, 7),
          port: sqlite3_column_type(query, 8) == SQLITE_NULL
            ? nil : UInt16(exactly: sqlite3_column_int(query, 8)),
          transport: transport, direction: direction)
        record.sequence = sqlite3_column_int64(query, 1)
        // 观察会话退休不代表收到连接关闭事件，不能将 retired_at 当作真实结束时间。
        let closed = optionalDouble(query, 3)
        record.closedAt = closed.flatMap { $0 <= end ? Date(timeIntervalSince1970: $0) : nil }
        if let received = text(query, 11).flatMap(UInt64.init),
          let sent = text(query, 12).flatMap(UInt64.init),
          let at = optionalDouble(query, 13)
        {
          record.traffic = .init(
            id: id, timestamp: Date(timeIntervalSince1970: at),
            receivedBytes: received, sentBytes: sent)
        }
        let location = text(query, 15).flatMap {
          try? JSONDecoder().decode(NetworkIPLocation.self, from: Data($0.utf8))
        }
        return (record, text(query, 14), location)
      }
      // 活动开关只改变分组计数，保留有历史但当前为零的分组；选择不限制侧栏。
      var groups: [NetworkHistoryGroup] = []
      if filter.grouping != "country" {
        groups = try rows(
          """
          SELECT \(group.key),\(group.name),\(group.path),\(group.pid),
            SUM(CASE WHEN ?5=0 OR (\(active)) THEN 1 ELSE 0 END),MIN(c.path)
          FROM connections c LEFT JOIN geography g ON g.address=c.address
          WHERE \(matching) GROUP BY \(group.key)
          ORDER BY 2 COLLATE NOCASE,1 LIMIT 512
          """, base
        ) { query in
          var name = text(query, 1) ?? "??"
          if filter.grouping == "process",
            text(query, 2) == nil, let path = text(query, 5), !path.isEmpty
          {
            // 旧记录可能存着版本号；只解析已聚合的路径，不扫描磁盘或改写历史。
            name = ObservedConnection.executableName(path: path, processID: 0)
          }
          return NetworkHistoryGroup(
            id: text(query, 0) ?? "??", name: name,
            applicationPath: text(query, 2),
            processID: sqlite3_column_type(query, 3) == SQLITE_NULL
              ? nil : sqlite3_column_int(query, 3),
            count: Int(sqlite3_column_int64(query, 4)))
        }
      }
      if filter.grouping == "country" {
        for depth in 0...2 {
          let parents = filter.expandedRegions.filter {
            NetworkRegionHierarchy.depth($0) == depth - 1
          }.sorted()
          if depth > 0 && parents.isEmpty { continue }
          let region = "network_history_region_level(\(group.key),\(depth))"
          let parent = "network_history_region_level(\(group.key),\(depth - 1))"
          let placeholders = parents.indices.map { "?\($0 + 7)" }.joined(separator: ",")
          let expanded = depth == 0 ? "1" : "\(parent) IN (\(placeholders))"
          // 各层独立在完整记录集上汇总，父级总数不受城市数量或详情分页限制。
          let level = try rows(
            """
            SELECT \(region),COUNT(*),MAX(CASE WHEN
              network_history_region_level(\(group.key),\(depth + 1)) IS NOT NULL THEN 1 ELSE 0 END)
            FROM connections c LEFT JOIN geography g ON g.address=c.address
            WHERE \(matching) AND (?5=0 OR (\(active))) AND \(expanded) AND \(region) IS NOT NULL
            GROUP BY \(region) ORDER BY 1 LIMIT 512
            """, base + parents.map(Value.text)
          ) { query in
            NetworkHistoryGroup(
              id: text(query, 0) ?? "??", name: text(query, 0) ?? "??",
              applicationPath: nil, processID: nil, count: Int(sqlite3_column_int64(query, 1)),
              hasChildren: sqlite3_column_int(query, 2) != 0)
          }
          groups += level
        }
      }
      let regionKey = groupExpression("country").key
      let regions = try rows(
        """
        SELECT \(regionKey),COUNT(*),MAX(c.opened_at)
        FROM connections c LEFT JOIN geography g ON g.address=c.address
        WHERE \(pagePredicate) GROUP BY \(regionKey) ORDER BY 3 DESC,1 LIMIT 64
        """, base
      ) { query in
        NetworkHistoryRegion(
          key: text(query, 0) ?? "??", count: Int(sqlite3_column_int64(query, 1)),
          latest: Date(timeIntervalSince1970: sqlite3_column_double(query, 2)))
      }
      var countries: [String: String] = [:]
      var locations: [String: NetworkIPLocation] = [:]
      for (record, country, location) in page {
        if let address = record.address, let country { countries[address] = country }
        if let address = record.address, let location { locations[address] = location }
      }
      return NetworkHistoryView(
        records: page.map(\.0), total: total, groups: groups,
        points: try points(filter: filter, now: end, earliest: seconds - Self.retention),
        countries: countries, locations: locations, regions: regions
      )
    }
    if didPrune { nextPruneAt = seconds + (pruneHasMore ? 0 : 15) }
    try checkpointIfNeeded(now: seconds)
    return result
  }

  func pendingAddresses(limit: Int = 256) throws -> [String] {
    try rows(
      """
      SELECT address FROM connections WHERE country IS NULL AND address IS NOT NULL
        AND address<>'' GROUP BY address ORDER BY address LIMIT ?
      """, [.integer(Int64(min(256, max(0, limit))))]
    ) { text($0, 0) ?? "" }
  }

  func updateCountries(_ countries: [String: String]) throws {
    try transaction {
      for (address, country) in countries {
        try Task.checkCancellation()
        guard !country.isEmpty, country.utf8.count <= 8 else { throw Failure.invalidData }
        try execute(
          "UPDATE connections SET country=? WHERE address=? AND country IS NOT ?",
          [.text(country), .text(address), .text(country)])
      }
    }
  }

  func pendingLocationAddresses(version: String, limit: Int = 256) throws -> [String] {
    try rows(
      """
      SELECT c.address FROM connections c LEFT JOIN geography g ON g.address=c.address
      WHERE c.address IS NOT NULL AND c.address<>'' AND (g.version IS NULL OR g.version<>?)
      GROUP BY c.address ORDER BY c.address LIMIT ?
      """, [.text(version), .integer(Int64(min(256, max(0, limit))))]
    ) { text($0, 0) ?? "" }
  }

  /// 每个地址只存一份详情；只接受仍有历史的地址，迟到查询不能复活已清空的数据。
  func updateLocations(_ locations: [String: NetworkIPLocation], version: String) throws {
    guard version.utf8.count <= 64 else { throw Failure.invalidData }
    try transaction {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      for (address, location) in locations {
        try Task.checkCancellation()
        guard address.utf8.count <= 128,
          [location.province, location.city, location.provider].allSatisfy({ $0.utf8.count <= 256 }
          ),
          location.longitude.map({ $0.isFinite && (-180...180).contains($0) }) ?? true,
          location.latitude.map({ $0.isFinite && (-90...90).contains($0) }) ?? true
        else { throw Failure.invalidData }
        let json = String(decoding: try encoder.encode(location), as: UTF8.self)
        try execute(
          """
          INSERT INTO geography(address,version,place_key,location)
          SELECT ?1,?2,?3,?4 WHERE EXISTS(SELECT 1 FROM connections WHERE address=?1)
          ON CONFLICT(address) DO UPDATE SET version=excluded.version,
            place_key=excluded.place_key,location=excluded.location
          WHERE geography.version<>excluded.version OR geography.location<>excluded.location
          """,
          [.text(address), .text(version), location.mapKey.map(Value.text) ?? .null, .text(json)])
      }
    }
  }

  func diagnostics() throws -> Diagnostics {
    let connectionRows = Int(try scalar("SELECT COUNT(*) FROM connections"))
    let trafficRows = Int(try scalar("SELECT COUNT(*) FROM traffic"))
    let trafficTotalRows = Int(try scalar("SELECT COUNT(*) FROM traffic_totals"))
    let cursorRows = Int(try scalar("SELECT COUNT(*) FROM cursors"))
    let pageCount = Int(try scalar("PRAGMA page_count"))
    let pageSize = Int(try scalar("PRAGMA page_size"))
    let discarded = try scalar("SELECT COALESCE(SUM(discarded),0) FROM cursors")
    let captureDropped = try scalar("SELECT COALESCE(SUM(capture_dropped),0) FROM cursors")
    let db = try open()
    let files = try fileSizes()
    var cache: Int32 = 0
    var highwater: Int32 = 0
    try check(sqlite3_db_status(db.handle, SQLITE_DBSTATUS_CACHE_USED, &cache, &highwater, 0))
    return Diagnostics(
      connectionRows: connectionRows, trafficRows: trafficRows, trafficTotalRows: trafficTotalRows,
      cursorRows: cursorRows,
      pageCount: pageCount, pageSize: pageSize, databaseBytes: pageCount * pageSize,
      databaseFileBytes: files.database, walBytes: files.wal, storageBytes: files.total,
      cacheBytes: Int(cache), preparedStatementCount: db.statements.count,
      discarded: discarded, captureDropped: captureDropped)
  }

  func clear() throws {
    committedIngest = nil
    try transaction {
      // 保留单个时间水位，阻止已取消读取的迟到结果或重启回放复活旧历史。
      try execute(
        """
        INSERT INTO settings(singleton,clear_before) VALUES(1,?)
        ON CONFLICT(singleton) DO UPDATE SET clear_before=MAX(clear_before,excluded.clear_before)
        """, [.real(Date().timeIntervalSince1970)])
    }
    // 清空也分小事务，避免 DELETE 把整个历史库复制到一个无法 checkpoint 的 WAL 中。
    for (table, key, limit) in [
      ("traffic_totals", "bucket", 4096),
      ("traffic", "epoch,id,bucket,segment", 4096),
      ("connections", "epoch,id", 1024),
      ("geography", "address", 1024),
      ("cursors", "epoch", 1024),
    ] {
      while try transaction({
        try execute(
          "DELETE FROM \(table) WHERE (\(key)) IN (SELECT \(key) FROM \(table) LIMIT \(limit))")
        return sqlite3_changes(try open().handle)
      }) > 0 {
        try Task.checkCancellation()
      }
    }
    try transaction {
      try execute("DELETE FROM state")
      // 回收每个空闲页都会返回 SQLITE_ROW，须消费完中间结果才能提交事务。
      _ = try rows("PRAGMA incremental_vacuum(128)") { _ in true }
    }
    owner = UUID().uuidString
    nextPruneAt = -Double.infinity
    let db = try open()
    try check(sqlite3_wal_checkpoint_v2(db.handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil))
    sqlite3_db_release_memory(db.handle)
  }

  /// 释放所有语句和页缓存；新的 owner 使重新打开时不能延续旧基线。
  func close() {
    if let database {
      let code = sqlite3_wal_checkpoint_v2(
        database.handle, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
      if code != SQLITE_OK { report(code) }
    }
    database = nil
    owner = UUID().uuidString
    nextPruneAt = -Double.infinity
    nextCheckpointAt = -Double.infinity
    committedIngest = nil
  }

  private func observationState(
    session: String, epoch: String, startedAt: Double, now: Double
  ) throws -> State {
    let previous = try rows(
      "SELECT session,epoch,owner,started_at,segment FROM state WHERE singleton=1"
    ) { query in
      State(
        session: text(query, 0) ?? "", epoch: text(query, 1) ?? "", owner: text(query, 2) ?? "",
        startedAt: sqlite3_column_double(query, 3), segment: sqlite3_column_int64(query, 4))
    }.first
    if let previous, previous.session == session, previous.epoch == epoch,
      previous.owner == owner, previous.startedAt == startedAt
    {
      return previous
    }
    let segment = (previous?.segment ?? 0) + 1
    // 旧会话未收到 close 的连接按暂停时刻退休；仍活跃的长连接可被后续增量重新激活。
    try execute(
      "UPDATE connections SET retired_at=? WHERE closed_at IS NULL AND retired_at IS NULL",
      [.real(now)])
    try execute(
      """
      INSERT INTO state(singleton,session,epoch,owner,started_at,segment) VALUES(1,?,?,?,?,?)
      ON CONFLICT(singleton) DO UPDATE SET session=excluded.session,epoch=excluded.epoch,
        owner=excluded.owner,started_at=excluded.started_at,segment=excluded.segment
      """,
      [.text(session), .text(epoch), .text(owner), .real(startedAt), .integer(segment)])
    return State(
      session: session, epoch: epoch, owner: owner, startedAt: startedAt, segment: segment)
  }

  private func validate(_ record: ObservedConnection, cursor: Int64) throws {
    guard record.sequence > 0, record.sequence <= cursor,
      record.timestamp.timeIntervalSince1970.isFinite,
      abs(record.timestamp.timeIntervalSince1970) < 1e12,
      record.closedAt?.timeIntervalSince1970.isFinite ?? true,
      record.closedAt.map({ $0 >= record.timestamp }) ?? true,
      record.traffic.map({
        $0.id == record.id && $0.timestamp.timeIntervalSince1970.isFinite
          && abs($0.timestamp.timeIntervalSince1970) < 1e12
      }) ?? true
    else { throw Failure.invalidData }
  }

  private func save(
    _ record: ObservedConnection, epoch: String, state: State
  ) throws {
    let key = record.applicationGroupKey
    let evidence = (record.traffic?.timestamp ?? record.closedAt ?? record.timestamp)
      .timeIntervalSince1970
    let liveSession: Value = evidence >= state.startedAt ? .text(state.session) : .null
    try execute(
      """
      INSERT INTO connections(
        epoch,id,sequence,opened_at,closed_at,pid,path,application_path,name,app_key,
        process_key,address,hostname,port,transport,direction,live_session,live_owner,last_seen,country
      ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,(
        SELECT country FROM connections WHERE address=? AND country IS NOT NULL LIMIT 1))
      ON CONFLICT(epoch,id) DO UPDATE SET sequence=excluded.sequence,
        closed_at=COALESCE(excluded.closed_at,connections.closed_at),
        pid=excluded.pid,path=excluded.path,application_path=excluded.application_path,
        name=excluded.name,app_key=excluded.app_key,process_key=excluded.process_key,
        address=COALESCE(excluded.address,connections.address),
        hostname=COALESCE(excluded.hostname,connections.hostname),port=excluded.port,
        transport=excluded.transport,direction=excluded.direction,
        live_session=excluded.live_session,live_owner=excluded.live_owner,retired_at=NULL,
        last_seen=MAX(connections.last_seen,excluded.last_seen)
      WHERE excluded.sequence>connections.sequence
      """,
      [
        .text(epoch), .text(record.id.uuidString), .integer(record.sequence),
        .real(record.timestamp.timeIntervalSince1970),
        record.closedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
        .integer(Int64(record.processID)), .text(record.executablePath),
        record.applicationPath.map(Value.text) ?? .null, .text(record.applicationName), .text(key),
        .text("\(record.executablePath)#\(record.processID)"),
        record.address.map(Value.text) ?? .null, record.hostname.map(Value.text) ?? .null,
        record.port.map { .integer(Int64($0)) } ?? .null,
        .text(record.transport.rawValue), .text(record.direction.rawValue),
        liveSession, .text(owner), .real(evidence), record.address.map(Value.text) ?? .null,
      ])
  }

  private func establishOpeningBaseline(
    _ record: ObservedConnection, epoch: String, state: State
  ) throws {
    let at = record.timestamp.timeIntervalSince1970
    guard at >= state.startedAt else { return }
    try execute(
      """
      UPDATE connections SET base_rx='0',base_tx='0',base_at=?,base_session=?,base_owner=?,
        base_segment=?,last_rx='0',last_tx='0',last_at=?
      WHERE epoch=? AND id=? AND last_at IS NULL
      """,
      [
        .real(at), .text(state.session), .text(owner), .integer(state.segment), .real(at),
        .text(epoch), .text(record.id.uuidString),
      ])
  }

  private func sample(
    _ snapshot: ConnectionTrafficSnapshot, epoch: String, state: State, allowsClosed: Bool
  ) throws {
    let at = snapshot.timestamp.timeIntervalSince1970
    guard at.isFinite, abs(at) < 1e12 else { throw Failure.invalidData }
    let sourceSession = snapshot.observationID?.uuidString ?? state.session
    let hasSourceSession = snapshot.observationID != nil
    guard hasSourceSession || at >= state.startedAt else { return }
    let clearBefore = try rows("SELECT clear_before FROM settings WHERE singleton=1") {
      sqlite3_column_double($0, 0)
    }.first
    guard clearBefore.map({ at > $0 }) ?? true else { return }
    let id = snapshot.id.uuidString
    let previous = try rows(
      """
      SELECT base_rx,base_tx,base_at,base_session,base_owner,base_segment,closed_at,last_at
      FROM connections WHERE epoch=? AND id=?
      """, [.text(epoch), .text(id)]
    ) { query -> (Baseline, Double?) in
      (
        Baseline(
          received: text(query, 0).flatMap(UInt64.init), sent: text(query, 1).flatMap(UInt64.init),
          timestamp: optionalDouble(query, 2), session: text(query, 3), owner: text(query, 4),
          segment: sqlite3_column_int64(query, 5),
          closed: sqlite3_column_type(query, 6) != SQLITE_NULL),
        optionalDouble(query, 7)
      )
    }.first
    guard let (baseline, lastAt) = previous,
      allowsClosed || !baseline.closed, lastAt.map({ at > $0 }) ?? true
    else { return }
    if let start = baseline.timestamp, let received = baseline.received, let sent = baseline.sent,
      baseline.session == sourceSession, baseline.owner == owner,
      hasSourceSession || (baseline.segment == state.segment && start >= state.startedAt),
      at > start, at - start <= 15,
      snapshot.receivedBytes >= received, snapshot.sentBytes >= sent
    {
      let rx = Double(snapshot.receivedBytes - received)
      let tx = Double(snapshot.sentBytes - sent)
      let duration = at - start
      var bucket = floor(start / 5) * 5
      while bucket < at {
        let overlap = min(at, bucket + 5) - max(start, bucket)
        if overlap > 0 {
          try execute(
            """
            INSERT INTO traffic(epoch,id,bucket,segment,rx,tx) VALUES(?,?,?,?,?,?)
            ON CONFLICT(epoch,id,bucket,segment) DO UPDATE SET rx=rx+excluded.rx,tx=tx+excluded.tx
            """,
            [
              .text(epoch), .text(id), .real(bucket), .integer(state.segment),
              .real(rx * overlap / duration), .real(tx * overlap / duration),
            ])
          // 与原始增量及基线同事务；重放、写入失败或预算回滚不能重复累计全局桶。
          try execute(
            """
            INSERT INTO traffic_totals(bucket,segment,rx,tx) VALUES(?,?,?,?)
            ON CONFLICT(bucket) DO UPDATE SET segment=MAX(segment,excluded.segment),
              rx=rx+excluded.rx,tx=tx+excluded.tx
            """,
            [
              .real(bucket), .integer(state.segment),
              .real(rx * overlap / duration), .real(tx * overlap / duration),
            ])
        }
        bucket += 5
      }
    }
    // UInt64 的原始累计值用十进制 TEXT，差值在 Swift 中检查后才转为绘图 Double。
    try execute(
      """
      UPDATE connections SET last_rx=?,last_tx=?,last_at=?,base_rx=?,base_tx=?,base_at=?,
        base_session=?,base_owner=?,base_segment=?,live_session=?,live_owner=?,retired_at=NULL,
        last_seen=MAX(last_seen,?)
      WHERE epoch=? AND id=?
      """,
      [
        .text(String(snapshot.receivedBytes)), .text(String(snapshot.sentBytes)), .real(at),
        .text(String(snapshot.receivedBytes)), .text(String(snapshot.sentBytes)), .real(at),
        .text(sourceSession), .text(owner), .integer(state.segment),
        .text(state.session), .text(owner), .real(at), .text(epoch), .text(id),
      ])
  }

  private func points(filter: NetworkHistoryFilter, now: Double, earliest: Double) throws
    -> [NetworkTrafficPoint]
  {
    let end = ceil(now / 5) * 5
    let interval = min(Self.retention, max(5, filter.interval))
    let count = Int(ceil(interval / 5))
    let start = end - Double(count) * 5
    let retainedStart = max(start, ceil(earliest / 5) * 5)
    let key = groupExpression(filter.grouping).key
    let source: String
    let predicate: String
    let parameters: [Value]
    if filter.search.isEmpty, filter.selection == nil {
      // 全部走势读取独立全局桶，查询成本不随连接数量增加。
      source = "traffic_totals t"
      predicate = "t.bucket>=?1 AND t.bucket<?2"
      parameters = [.real(retainedStart), .real(end)]
    } else if filter.search.isEmpty, let selection = filter.selection,
      filter.grouping == "apps" || filter.grouping == "process"
    {
      // 先用应用/进程索引定位连接，再以复合主键读取对应流量；不扫描其他应用的桶。
      source = "traffic t"
      predicate = """
        t.bucket>=?1 AND t.bucket<?2 AND (t.epoch,t.id) IN (
          SELECT c.epoch,c.id FROM connections c WHERE \(key)=?3)
        """
      parameters = [.real(retainedStart), .real(end), .text(selection)]
    } else {
      source = """
        traffic t JOIN connections c ON c.epoch=t.epoch AND c.id=t.id
        LEFT JOIN geography g ON g.address=c.address
        """
      predicate = """
        t.bucket>=?1 AND t.bucket<?2
        AND \(Self.searchPredicate.replacingOccurrences(of: "?2", with: "?3"))
        AND (?4 IS NULL OR \(key)=?4
          \(filter.grouping == "country" ? "OR ((?4='CN' OR SUBSTR(?4,1,3)='CN|') AND SUBSTR(\(key),1,LENGTH(?4)+1)=?4||'|')" : ""))
        """
      parameters = [
        .real(retainedStart), .real(end), .text(filter.search),
        filter.selection.map(Value.text) ?? .null,
      ]
    }
    let values = try rows(
      """
      SELECT t.bucket,MAX(t.segment),SUM(t.rx)/5,SUM(t.tx)/5
      FROM \(source) WHERE \(predicate)
      GROUP BY t.bucket ORDER BY t.bucket LIMIT 180
      """, parameters
    ) { query in
      (
        sqlite3_column_double(query, 0), sqlite3_column_int64(query, 1),
        sqlite3_column_double(query, 2), sqlite3_column_double(query, 3)
      )
    }
    var points = (0..<count).map { index in
      NetworkTrafficPoint(
        date: Date(timeIntervalSince1970: start + Double(index + 1) * 5),
        receivedBytesPerSecond: nil, sentBytesPerSecond: nil, segment: 0)
    }
    for (bucket, segment, received, sent) in values {
      let index = Int(((bucket - start) / 5).rounded())
      guard points.indices.contains(index) else { continue }
      points[index].receivedBytesPerSecond = received
      points[index].sentBytesPerSecond = sent
      points[index].segment = Int(segment)
    }
    var drawingSegment = 0
    var previous: Int?
    for index in points.indices {
      guard points[index].receivedBytesPerSecond != nil else {
        previous = nil
        continue
      }
      let sourceSegment = points[index].segment
      if previous != sourceSegment { drawingSegment += 1 }
      points[index].segment = drawingSegment
      previous = sourceSegment
    }
    return points
  }

  private func groupExpression(_ grouping: String)
    -> (key: String, name: String, path: String, pid: String)
  {
    switch grouping {
    case "process": ("c.process_key", "MIN(c.name)", "MIN(c.application_path)", "MIN(c.pid)")
    case "domain":
      ("COALESCE(c.hostname,c.address,'??')", "COALESCE(c.hostname,c.address,'??')", "NULL", "NULL")
    case "country":
      (
        "COALESCE(g.place_key,NULLIF(c.country,'??'),network_history_region(c.address))",
        "COALESCE(g.place_key,NULLIF(c.country,'??'),network_history_region(c.address))", "NULL",
        "NULL"
      )
    default:
      (
        "c.app_key",
        "CASE WHEN SUBSTR(c.app_key,1,5)='name:' THEN SUBSTR(c.app_key,6) ELSE MIN(c.name) END",
        "MIN(c.application_path)", "NULL"
      )
    }
  }

  private static let searchPredicate = """
    (?2='' OR network_history_matches(c.name,c.path,c.address,c.hostname,c.pid,c.port,?2))
    """

  private func prune(now: Double) throws {
    let db = try open()
    let cutoff = now - Self.retention
    try execute(
      """
      DELETE FROM traffic_totals WHERE bucket IN (
        SELECT bucket FROM traffic_totals WHERE bucket<=? ORDER BY bucket LIMIT 4096)
      """, [.real(cutoff - 5)])
    pruneHasMore = sqlite3_changes(db.handle) == 4096
    try execute(
      """
      DELETE FROM traffic WHERE (epoch,id,bucket,segment) IN (
        SELECT epoch,id,bucket,segment FROM traffic WHERE bucket<=? ORDER BY bucket LIMIT 4096)
      """, [.real(cutoff - 5)])
    pruneHasMore = pruneHasMore || sqlite3_changes(db.handle) == 4096
    try execute(
      """
      DELETE FROM connections WHERE (epoch,id) IN (
        SELECT c.epoch,c.id FROM connections c
        WHERE (c.last_seen<? OR COALESCE(c.closed_at,c.retired_at)<?)
          AND NOT EXISTS(SELECT 1 FROM traffic t WHERE t.epoch=c.epoch AND t.id=c.id)
        LIMIT 1024)
      """, [.real(cutoff), .real(cutoff)])
    pruneHasMore = pruneHasMore || sqlite3_changes(db.handle) == 1024
    try execute(
      """
      DELETE FROM geography WHERE address IN (
        SELECT g.address FROM geography g
        WHERE NOT EXISTS(SELECT 1 FROM connections c WHERE c.address=g.address) LIMIT 1024)
      """)
    pruneHasMore = pruneHasMore || sqlite3_changes(db.handle) == 1024
    try execute(
      """
      DELETE FROM cursors WHERE epoch IN (
        SELECT epoch FROM cursors WHERE touched<?
          AND NOT EXISTS(SELECT 1 FROM connections c WHERE c.epoch=cursors.epoch)
          AND epoch<>(SELECT epoch FROM state WHERE singleton=1) LIMIT 1024)
      """, [.real(cutoff)])
  }

  private func checkpointIfNeeded(now: Double) throws {
    guard let database else { return }
    if now >= nextCheckpointAt {
      let code = sqlite3_wal_checkpoint_v2(
        database.handle, "main", SQLITE_CHECKPOINT_PASSIVE, nil, nil)
      if code != SQLITE_OK { report(code) }
      nextCheckpointAt = now + 60
    }
    try enforceStorageBudget(db: database)
  }

  private func fileSizes() throws -> FileSizes {
    guard let url else { return FileSizes(database: 0, wal: 0) }
    return FileSizes(
      database: try fileBytes(url.path), wal: try fileBytes(url.path + "-wal"))
  }

  private func fileBytes(_ path: String) throws -> Int {
    var information = stat()
    guard path.withCString({ lstat($0, &information) }) == 0 else {
      if errno == ENOENT { return 0 }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard let count = Int(exactly: information.st_size), count >= 0 else {
      throw Failure.invalidData
    }
    return count
  }

  private func fitsStorageBudget(_ files: FileSizes, reserving reserve: Int = 0) -> Bool {
    files.database <= Self.maximumDatabaseBytes
      && files.wal <= walBudgetBytes - reserve
      && files.total <= Self.maximumDatabaseBytes + walBudgetBytes - reserve
  }

  private func enforceStorageBudget(db: Database) throws {
    guard url != nil, try !fitsStorageBudget(fileSizes()) else { return }
    try truncateForBudget(db: db)
  }

  /// 预算不是文件系统配额；被外部读者钉住时停止写入并报错，不靠丢弃合法历史腾空间。
  private func truncateForBudget(db: Database) throws {
    let code = sqlite3_wal_checkpoint_v2(
      db.handle, "main", SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    if code != SQLITE_OK {
      report(code)
      throw Failure.storageBudgetExceeded
    }
    guard try fitsStorageBudget(fileSizes()) else { throw Failure.storageBudgetExceeded }
  }

  private func commitFitsStorageBudget(db: Database) throws -> Bool {
    guard url != nil else { return true }
    let pageSize = Int(try scalar("PRAGMA page_size", db: db))
    var cache: Int32 = 0
    var highwater: Int32 = 0
    try check(sqlite3_db_status(db.handle, SQLITE_DBSTATUS_CACHE_USED, &cache, &highwater, 0))
    // WAL 由 32 字节文件头、每帧 24 字节帧头及一个数据库页组成。
    // 大部分事务只需 stat；接近水位时才刷出脏页，避免每批强制缓存刷盘。
    let commitReserve = 32 + 2 * (pageSize + 24)
    let cacheReserve = Int(cache) + (Int(cache) / pageSize + 1) * 24 + commitReserve
    if try fitsStorageBudget(fileSizes(), reserving: cacheReserve) { return true }
    try check(sqlite3_db_cacheflush(db.handle))
    // 所有查询均已 reset；为缓存刷出时仍可能在用的首页及提交帧留余量。
    return try fitsStorageBudget(fileSizes(), reserving: commitReserve)
  }

  private func open() throws -> Database {
    if let database { return database }
    if let url {
      guard url.isFileURL else { throw Failure.invalidData }
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      // 独占创建只设置新文件权限，不截断已有数据库，也不修改进程全局 umask。
      let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
      if descriptor >= 0 {
        Darwin.close(descriptor)
      } else if errno != EEXIST {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { throw Failure.invalidData }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    var handle: OpaquePointer?
    let code = sqlite3_open_v2(
      url?.path ?? ":memory:", &handle,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    guard code == SQLITE_OK, let handle else {
      if let handle { sqlite3_close_v2(handle) }
      report(code)
      throw Failure.database(code)
    }
    let db = Database(handle)
    try check(sqlite3_busy_timeout(handle, 1000))
    try check(
      sqlite3_create_function_v2(
        handle, "network_history_matches", 7, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
        networkHistoryMatches, nil, nil, nil))
    try check(
      sqlite3_create_function_v2(
        handle, "network_history_region", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
        networkHistoryRegion, nil, nil, nil))
    try check(
      sqlite3_create_function_v2(
        handle, "network_history_region_level", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
        networkHistoryRegionLevel, nil, nil, nil))
    // 主库页数上限 256 MiB；WAL 另有 64 MiB 检查水位，不能把总存储声称为 256 MiB。
    try raw(
      """
      PRAGMA auto_vacuum=INCREMENTAL;
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=NORMAL;
      PRAGMA cache_size=-2048;
      PRAGMA mmap_size=0;
      PRAGMA wal_autocheckpoint=256;
      PRAGMA journal_size_limit=8388608;
      """, db: db)
    let version = try scalar("PRAGMA user_version", db: db)
    guard (0...4).contains(version) else { throw Failure.unsupportedSchema }
    let size = try scalar("PRAGMA page_size", db: db)
    guard size > 0 else { throw Failure.invalidData }
    guard try scalar("PRAGMA page_count", db: db) <= Int64(Self.maximumDatabaseBytes) / size else {
      throw Failure.database(SQLITE_FULL)
    }
    try raw("PRAGMA max_page_count=\(Int64(Self.maximumDatabaseBytes) / size)", db: db)
    try enforceStorageBudget(db: db)
    try raw("BEGIN IMMEDIATE", db: db)
    do {
      try raw(Self.schema, db: db)
      if version == 1 {
        // 只在旧版迁移时聚合一次；全程 SQL，不把历史逐行解码到 Swift 内存。
        try raw(
          """
          INSERT INTO traffic_totals(bucket,segment,rx,tx)
            SELECT bucket,MAX(segment),SUM(rx),SUM(tx) FROM traffic GROUP BY bucket;
          """, db: db)
      }
      if version < 4 {
        // 旧库一次性更新索引键；逐行由 SQLite 调用纯路径解析，不把历史载入内存。
        try check(
          sqlite3_create_function_v2(
            handle, "network_history_app_key", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            networkHistoryApplicationKey, nil, nil, nil))
        try raw(
          "UPDATE connections SET app_key=network_history_app_key(path,pid)", db: db)
      }
      try raw("PRAGMA user_version=4", db: db)
      try raw("COMMIT", db: db)
    } catch {
      if sqlite3_get_autocommit(db.handle) == 0 {
        _ = sqlite3_exec(db.handle, "ROLLBACK", nil, nil, nil)
      }
      throw error
    }
    try enforceStorageBudget(db: db)
    database = db
    return db
  }

  private static let schema = """
    CREATE TABLE IF NOT EXISTS connections(
      epoch TEXT NOT NULL,id TEXT NOT NULL,sequence INTEGER NOT NULL,opened_at REAL NOT NULL,
      closed_at REAL,pid INTEGER NOT NULL,path TEXT NOT NULL,application_path TEXT,name TEXT NOT NULL,
      app_key TEXT NOT NULL,process_key TEXT NOT NULL,address TEXT,hostname TEXT,port INTEGER,
      transport TEXT NOT NULL,direction TEXT NOT NULL,country TEXT,retired_at REAL,last_seen REAL NOT NULL,
      live_session TEXT,live_owner TEXT,last_rx TEXT,last_tx TEXT,last_at REAL,
      base_rx TEXT,base_tx TEXT,base_at REAL,base_session TEXT,base_owner TEXT,base_segment INTEGER,
      PRIMARY KEY(epoch,id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS connections_opened ON connections(opened_at DESC,id);
    CREATE INDEX IF NOT EXISTS connections_ended ON connections(COALESCE(closed_at,retired_at));
    CREATE INDEX IF NOT EXISTS connections_seen ON connections(last_seen);
    CREATE INDEX IF NOT EXISTS connections_address ON connections(address,country);
    CREATE INDEX IF NOT EXISTS connections_app ON connections(app_key);
    CREATE INDEX IF NOT EXISTS connections_process ON connections(process_key);
    CREATE TABLE IF NOT EXISTS traffic(
      epoch TEXT NOT NULL,id TEXT NOT NULL,bucket REAL NOT NULL,segment INTEGER NOT NULL,
      rx REAL NOT NULL,tx REAL NOT NULL,PRIMARY KEY(epoch,id,bucket,segment)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS geography(
      address TEXT PRIMARY KEY,version TEXT NOT NULL,place_key TEXT,location TEXT NOT NULL
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS traffic_time ON traffic(bucket);
    CREATE TABLE IF NOT EXISTS traffic_totals(
      bucket REAL PRIMARY KEY,segment INTEGER NOT NULL,rx REAL NOT NULL,tx REAL NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS cursors(
      epoch TEXT PRIMARY KEY,sequence INTEGER NOT NULL,discarded INTEGER NOT NULL,
      capture_dropped INTEGER NOT NULL,touched REAL NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS state(
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),session TEXT NOT NULL,epoch TEXT NOT NULL,
      owner TEXT NOT NULL,started_at REAL NOT NULL,segment INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS settings(
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),clear_before REAL NOT NULL
    );
    """

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    let db = try open()
    for attempt in 0..<2 {
      try enforceStorageBudget(db: db)
      try raw("BEGIN IMMEDIATE", db: db)
      do {
        let value = try body()
        if try !commitFitsStorageBudget(db: db) {
          // 不在写事务内 checkpoint：先回滚本批和游标，再收缩 WAL，最多重做一次。
          try raw("ROLLBACK", db: db)
          try truncateForBudget(db: db)
          if attempt == 0 { continue }
          throw Failure.storageBudgetExceeded
        }
        try raw("COMMIT", db: db)
        lastError = nil
        return value
      } catch {
        // SQLITE_FULL 等错误可能已自动回滚；不能用二次回滚的状态覆盖原始失败。
        if sqlite3_get_autocommit(db.handle) == 0 {
          _ = sqlite3_exec(db.handle, "ROLLBACK", nil, nil, nil)
        }
        throw error
      }
    }
    throw Failure.storageBudgetExceeded
  }

  private func raw(_ sql: String, db: Database) throws {
    try check(sqlite3_exec(db.handle, sql, nil, nil, nil))
  }

  private func query(_ sql: String, _ values: [Value], db: Database) throws -> OpaquePointer {
    let statement: OpaquePointer
    if let cached = db.statements[sql] {
      statement = cached
    } else {
      var prepared: OpaquePointer?
      try check(sqlite3_prepare_v2(db.handle, sql, -1, &prepared, nil))
      guard let prepared else { throw Failure.database(SQLITE_ERROR) }
      statement = prepared
      db.statements[sql] = prepared
    }
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, value) in values.enumerated() {
      let position = Int32(index + 1)
      let result: Int32
      switch value {
      case .text(let string):
        result = string.withCString { sqlite3_bind_text(statement, position, $0, -1, transient) }
      case .integer(let integer): result = sqlite3_bind_int64(statement, position, integer)
      case .real(let real): result = sqlite3_bind_double(statement, position, real)
      case .null: result = sqlite3_bind_null(statement, position)
      }
      try check(result)
    }
    return statement
  }

  private func execute(_ sql: String, _ values: [Value] = []) throws {
    let statement = try query(sql, values, db: open())
    defer { sqlite3_reset(statement) }
    try check(sqlite3_step(statement), expecting: SQLITE_DONE)
  }

  private func scalar(_ sql: String, _ values: [Value] = [], db: Database? = nil) throws -> Int64 {
    let statement = try query(sql, values, db: db ?? open())
    defer { sqlite3_reset(statement) }
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return 0 }
    try check(status, expecting: SQLITE_ROW)
    return sqlite3_column_int64(statement, 0)
  }

  private func rows<T>(
    _ sql: String, _ values: [Value] = [], decode: (OpaquePointer) throws -> T
  ) throws -> [T] {
    let statement = try query(sql, values, db: open())
    defer { sqlite3_reset(statement) }
    var result: [T] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      try Task.checkCancellation()
      result.append(try decode(statement))
      status = sqlite3_step(statement)
    }
    try check(status, expecting: SQLITE_DONE)
    return result
  }

  private func text(_ query: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_text(query, column).map { String(cString: $0) }
  }

  private func optionalDouble(_ query: OpaquePointer, _ column: Int32) -> Double? {
    sqlite3_column_type(query, column) == SQLITE_NULL ? nil : sqlite3_column_double(query, column)
  }

  private func check(_ code: Int32, expecting: Int32 = SQLITE_OK) throws {
    guard code == expecting else {
      report(code)
      throw Failure.database(code)
    }
  }

  private func report(_ code: Int32) {
    guard code != lastError else { return }
    lastError = code
    Self.log.error("网络历史数据库失败：SQLite \(code)")
  }
}

/// SQLite 内完成 Unicode 大小写匹配；搜索始终绑定参数，百分号和引号只作为普通字符。
private func networkHistoryMatches(
  _ context: OpaquePointer?, _ count: Int32, _ arguments: UnsafeMutablePointer<OpaquePointer?>?
) {
  guard count == 7, let arguments, let rawSearch = sqlite3_value_text(arguments[6]) else {
    sqlite3_result_int(context, 0)
    return
  }
  let search = String(cString: rawSearch)
  if search.isEmpty {
    sqlite3_result_int(context, 1)
    return
  }
  for index in 0..<6 {
    if let raw = sqlite3_value_text(arguments[index]),
      String(cString: raw).range(of: search, options: .caseInsensitive) != nil
    {
      sqlite3_result_int(context, 1)
      return
    }
  }
  sqlite3_result_int(context, 0)
}

/// 只对无归属地址进行按需分类，避免改写已有历史或依赖地图库下载状态。
private func networkHistoryRegion(
  _ context: OpaquePointer?, _ count: Int32, _ arguments: UnsafeMutablePointer<OpaquePointer?>?
) {
  guard count == 1, let arguments else {
    sqlite3_result_error(context, "Invalid region arguments", -1)
    return
  }
  let address = sqlite3_value_text(arguments[0]).map { String(cString: $0) }
  OfflineGeography.regionKey(address: address).withCString {
    sqlite3_result_text(context, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  }
}

/// 仅用于升级分组索引，不读取文件或查询其他数据库。
private func networkHistoryApplicationKey(
  _ context: OpaquePointer?, _ count: Int32, _ arguments: UnsafeMutablePointer<OpaquePointer?>?
) {
  guard count == 2, let arguments, let rawPath = sqlite3_value_text(arguments[0]) else {
    sqlite3_result_error(context, "Invalid application path", -1)
    return
  }
  let key = ObservedConnection.applicationGroupKey(
    path: String(cString: rawPath), processID: sqlite3_value_int(arguments[1]))
  key.withCString {
    sqlite3_result_text(context, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  }
}

private func networkHistoryRegionLevel(
  _ context: OpaquePointer?, _ count: Int32, _ arguments: UnsafeMutablePointer<OpaquePointer?>?
) {
  guard count == 2, let arguments, let raw = sqlite3_value_text(arguments[0]),
    let key = NetworkRegionHierarchy.key(
      String(cString: raw), at: Int(sqlite3_value_int(arguments[1])))
  else {
    sqlite3_result_null(context)
    return
  }
  key.withCString {
    sqlite3_result_text(context, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  }
}
