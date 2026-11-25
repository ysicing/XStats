// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Darwin
import Foundation
import SQLite3

struct ActivitySession: Codable, Sendable, Identifiable, Equatable {
  let id: UUID
  let deviceID: UUID
  let appID: String
  let appName: String
  let category: String
  let start: Date
  var end: Date
  var deviceName: String?
  var subcategory: String?
}

actor ActivityStore {
  enum Failure: Error, Equatable {
    case batchTooLarge
    case invalidSession
    case invalidInterval
    case invalidDay
    case unsupportedSchema
    case authentication
    case database(Int32)
  }

  static let maximumBatchSize = 10_000
  private static let maximumAppFieldBytes = 1024
  private static let categories: Set<String> = [
    "work", "entertainment", "communication", "browsing", "other",
  ]
  private static let columns = "s.record_key, s.device_key, s.day_key, s.ciphertext"
  private static let tokenBytes = 32
  private static let sealedOverhead = 28
  private static let maximumCiphertextBytes = 16 * 1024
  private static let secondsPerDay: TimeInterval = 86_400
  private static let maximumIndexedDays = 32
  private static let maximumQueryDays = 128
  private static let utc = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
  private static let unixEpochOffset = Date.timeIntervalBetween1970AndReferenceDate
  private static let firstSupportedDay = -62_135_596_800.0 - unixEpochOffset
  private static let afterLastSupportedDay = 253_402_300_800.0 - unixEpochOffset

  private let url: URL?
  private let keyProvider: (@Sendable () throws -> SymmetricKey)?
  // 句柄仅由 actor 方法访问，析构时没有在途操作。
  nonisolated(unsafe) private var db: OpaquePointer?
  private var keys: Keys?

  init(url: URL?, keyProvider: (@Sendable () throws -> SymmetricKey)? = nil) {
    self.url = url
    self.keyProvider = keyProvider
  }

  deinit {
    if let db { sqlite3_close(db) }
  }

  func insert(_ sessions: [ActivitySession]) throws {
    guard sessions.count <= Self.maximumBatchSize else { throw Failure.batchTooLarge }
    guard !sessions.isEmpty else { return }
    for session in sessions {
      try Task.checkCancellation()
      guard validSession(session) else { throw Failure.invalidSession }
    }

    guard let (handle, keys) = try open(createIfMissing: true) else {
      throw Failure.database(SQLITE_CANTOPEN)
    }
    let encoder = JSONEncoder()
    try execute("BEGIN IMMEDIATE", on: handle)
    do {
      let insertRecord = """
        INSERT INTO activity_records (record_key, device_key, day_key, ciphertext) VALUES (?, ?, ?, ?)
        ON CONFLICT(record_key) DO NOTHING
        """
      let insertRange = """
        INSERT INTO activity_ranges (bucket, device_key, record_key) VALUES (?, ?, ?)
        """
      var latestNamed: [UUID: ActivitySession] = [:]
      try statement(insertRecord, on: handle) { recordQuery in
        try statement(insertRange, on: handle) { rangeQuery in
          var dayTokens: [Int: Data] = [:]
          let overflow = keys.token("range-overflow", "")
          for session in sessions {
            try Task.checkCancellation()
            let indexes = keys.indexes(for: session)
            let ciphertext = try keys.seal(encoder.encode(session), authenticating: indexes.aad)
            guard ciphertext.count <= Self.maximumCiphertextBytes else {
              throw Failure.invalidSession
            }
            try bind(indexes.record, at: 1, in: recordQuery)
            try bind(indexes.device, at: 2, in: recordQuery)
            try bind(indexes.day, at: 3, in: recordQuery)
            try bind(ciphertext, at: 4, in: recordQuery)
            try check(sqlite3_step(recordQuery), expected: SQLITE_DONE)
            let inserted = sqlite3_changes(handle) != 0
            try check(sqlite3_reset(recordQuery))
            guard inserted else { continue }
            if session.deviceName != nil,
              latestNamed[session.deviceID].map({ $0.end < session.end }) ?? true
            {
              latestNamed[session.deviceID] = session
            }

            let days = Self.days(start: session.start, end: session.end)
            let tokens: [Data]
            if days.count > Self.maximumIndexedDays {
              tokens = [overflow]
            } else {
              tokens = days.map { day in
                if let token = dayTokens[day] { return token }
                let token = keys.token("range-day", String(day))
                if dayTokens.count < Self.maximumQueryDays { dayTokens[day] = token }
                return token
              }
            }
            for token in tokens {
              try bind(token, at: 1, in: rangeQuery)
              try bind(indexes.device, at: 2, in: rangeQuery)
              try bind(indexes.record, at: 3, in: rangeQuery)
              try check(sqlite3_step(rangeQuery), expected: SQLITE_DONE)
              try check(sqlite3_reset(rangeQuery))
            }
          }
        }
      }
      for session in latestNamed.values {
        try updateDeviceNameIndex(session, on: handle, keys: keys)
      }
      try Task.checkCancellation()
      try execute("COMMIT", on: handle)
    } catch {
      sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
      throw error
    }
  }

  /// 使用半开区间，恰好在查询起点结束或在查询终点开始的记录不相交。
  func sessions(
    in interval: DateInterval, deviceID: UUID? = nil, including recent: [ActivitySession] = []
  ) throws -> [ActivitySession] {
    let start = interval.start.timeIntervalSinceReferenceDate
    let end = interval.end.timeIntervalSinceReferenceDate
    guard start.isFinite, end.isFinite else { throw Failure.invalidInterval }
    guard start < end else { return [] }
    guard recent.count <= Self.maximumBatchSize else { throw Failure.batchTooLarge }

    var recentByID: [UUID: ActivitySession] = [:]
    for session in recent {
      try Task.checkCancellation()
      let sessionStart = session.start.timeIntervalSinceReferenceDate
      let sessionEnd = session.end.timeIntervalSinceReferenceDate
      guard deviceID == nil || session.deviceID == deviceID,
        sessionStart >= Self.firstSupportedDay, sessionEnd <= Self.afterLastSupportedDay,
        sessionStart < sessionEnd, sessionStart < end, sessionEnd > start,
        recentByID[session.id] == nil
      else { continue }
      recentByID[session.id] = session
    }

    var sessions: [ActivitySession] = []
    let clippedStart = max(start, Self.firstSupportedDay)
    let clippedEnd = min(end, Self.afterLastSupportedDay)
    if clippedStart < clippedEnd, let (handle, keys) = try open() {
      let days = Self.days(
        start: Date(timeIntervalSinceReferenceDate: clippedStart),
        end: Date(timeIntervalSinceReferenceDate: clippedEnd))
      try readCandidates(days: days, deviceID: deviceID, on: handle, keys: keys) { session in
        guard session.start < interval.end, session.end > interval.start else { return }
        recentByID.removeValue(forKey: session.id)
        sessions.append(session)
      }
    }

    sessions.append(contentsOf: recentByID.values)
    try sort(&sessions)
    return sessions
  }

  func deviceIDs() throws -> [UUID] {
    guard let (handle, keys) = try open() else { return [] }
    var devices: [UUID] = []
    try scan(
      "SELECT \(Self.columns) FROM activity_records AS s GROUP BY s.device_key", on: handle
    ) { query in
      devices.append(try decodeSession(query, keys: keys).deviceID)
    }
    return devices.sorted { $0.uuidString < $1.uuidString }
  }

  // 每台设备只索引最新一条有名称的密文记录。单独的 HMAC 域与日期索引隔离，旧库也可直接使用。
  private static let namedDevicesSQL = """
    SELECT \(columns) FROM activity_ranges AS r JOIN activity_records AS s
    ON s.record_key = r.record_key AND s.device_key = r.device_key WHERE r.bucket = ?
    """

  func deviceNames() throws -> [UUID: String] {
    guard let (handle, keys) = try open() else { return [:] }
    let bucket = keys.token("device-name", "")
    var names: [UUID: String] = [:]
    try scan(Self.namedDevicesSQL, on: handle, bind: { try bind(bucket, at: 1, in: $0) }) {
      let session = try decodeSession($0, keys: keys)
      names[session.deviceID] = session.deviceName
    }
    return names
  }

  private func updateDeviceNameIndex(
    _ session: ActivitySession, on handle: OpaquePointer, keys: Keys
  ) throws {
    let bucket = keys.token("device-name", "")
    let indexes = keys.indexes(for: session)
    let bindDevice: (OpaquePointer) throws -> Void = { [self] query in
      try bind(bucket, at: 1, in: query)
      try bind(indexes.device, at: 2, in: query)
    }
    var latestEnd: Date?
    try scan(Self.namedDevicesSQL + " AND r.device_key = ?", on: handle, bind: bindDevice) {
      latestEnd = try decodeSession($0, keys: keys).end
    }
    if let latestEnd, latestEnd >= session.end { return }
    try statement("DELETE FROM activity_ranges WHERE bucket = ? AND device_key = ?", on: handle) {
      try bindDevice($0)
      try check(sqlite3_step($0), expected: SQLITE_DONE)
    }
    try statement(
      "INSERT INTO activity_ranges (bucket,device_key,record_key) VALUES (?,?,?)", on: handle
    ) {
      try bindDevice($0)
      try bind(indexes.record, at: 3, in: $0)
      try check(sqlite3_step($0), expected: SQLITE_DONE)
    }
  }

  func localDays(deviceID: UUID) throws -> [String] {
    guard let (handle, keys) = try open() else { return [] }
    let sql = """
      SELECT \(Self.columns) FROM activity_records AS s WHERE s.device_key = ? GROUP BY s.day_key
      """
    let decoder = JSONDecoder()
    var days: [String] = []
    try scan(sql, on: handle, bind: { try bind(keys.device(deviceID), at: 1, in: $0) }) { query in
      let session = try decodeSession(query, keys: keys, decoder: decoder)
      let day = Self.dayIndex(session.start)
      days.append(
        Date(timeIntervalSinceReferenceDate: Double(day) * Self.secondsPerDay).formatted(Self.utc))
    }
    return days.sorted()
  }

  func exportDay(_ day: String, deviceID: UUID) throws -> [ActivitySession] {
    guard day.utf8.prefix(11).count == 10, day >= "0001-01-01",
      let date = try? Self.utc.parse(day), date.formatted(Self.utc) == day
    else { throw Failure.invalidDay }
    guard let (handle, keys) = try open() else { return [] }
    let sql = """
      SELECT \(Self.columns) FROM activity_records AS s WHERE s.device_key = ? AND s.day_key = ?
      """
    let decoder = JSONDecoder()
    var sessions: [ActivitySession] = []
    try scan(
      sql, on: handle,
      bind: { query in
        try bind(keys.device(deviceID), at: 1, in: query)
        try bind(keys.startDay(Self.dayIndex(date), deviceID: deviceID), at: 2, in: query)
      }
    ) { query in
      sessions.append(try decodeSession(query, keys: keys, decoder: decoder))
    }
    try sort(&sessions)
    return sessions
  }

  private func readCandidates(
    days: ClosedRange<Int>, deviceID: UUID?, on handle: OpaquePointer, keys: Keys,
    visit: (ActivitySession) throws -> Void
  ) throws {
    let device = deviceID.map { keys.device($0) }
    let decoder = JSONDecoder()
    // 普通查询只读取相交的 UTC 日桶。极长记录使用单独的桶，以限制每条记录的索引大小。
    // 大范围查询直接遍历匹配设备的记录，以限制 SQL 参数数量。
    guard days.count <= Self.maximumQueryDays else {
      let condition = device == nil ? "" : " WHERE s.device_key = ?"
      let sql = "SELECT \(Self.columns) FROM activity_records AS s\(condition)"
      try scan(
        sql, on: handle, bind: { if let device { try bind(device, at: 1, in: $0) } }
      ) { query in
        try visit(decodeSession(query, keys: keys, decoder: decoder))
      }
      return
    }

    let buckets = Dictionary(
      uniqueKeysWithValues: days.map { (keys.token("range-day", String($0)), $0) })
    let overflow = keys.token("range-overflow", "")
    let tokens = Array(buckets.keys) + [overflow]
    let parameters = Array(repeating: "?", count: tokens.count).joined(separator: ",")
    let condition = device == nil ? "" : " AND r.device_key = ?"
    let sql = """
      SELECT \(Self.columns), r.bucket, r.device_key FROM activity_ranges AS r
      LEFT JOIN activity_records AS s ON s.record_key = r.record_key
      WHERE r.bucket IN (\(parameters))\(condition) ORDER BY r.record_key
      """
    var last: (record: Data, device: Data, days: ClosedRange<Int>)?
    try scan(
      sql, on: handle,
      bind: { query in
        for (offset, token) in tokens.enumerated() {
          try bind(token, at: Int32(offset + 1), in: query)
        }
        if let device { try bind(device, at: Int32(tokens.count + 1), in: query) }
      }
    ) { query in
      let record = try token(at: 0, in: query)
      let bucket = try token(at: 4, in: query)
      let rangeDevice = try token(at: 5, in: query)
      let entry: (record: Data, device: Data, days: ClosedRange<Int>)
      let session: ActivitySession?
      if let last, last.record == record {
        entry = last
        session = nil
      } else {
        let decoded = try decodeSession(query, keys: keys, decoder: decoder)
        entry = (
          record, try token(at: 1, in: query), Self.days(start: decoded.start, end: decoded.end)
        )
        session = decoded
      }
      let validBucket =
        entry.days.count > Self.maximumIndexedDays
        ? bucket == overflow : buckets[bucket].map { entry.days.contains($0) } == true
      guard validBucket, rangeDevice == entry.device else { throw Failure.authentication }
      last = entry
      if let session { try visit(session) }
    }
  }

  private static func dayIndex(_ date: Date) -> Int {
    Int(floor(floor(date.timeIntervalSinceReferenceDate) / secondsPerDay))
  }

  private static func days(start: Date, end: Date) -> ClosedRange<Int> {
    let last = dayIndex(end)
    let midnight = Double(last) * secondsPerDay
    return dayIndex(start)...(end.timeIntervalSinceReferenceDate == midnight ? last - 1 : last)
  }

  private func sort(_ sessions: inout [ActivitySession]) throws {
    try sessions.sort {
      try Task.checkCancellation()
      return $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
    }
  }

  private func validSession(_ session: ActivitySession) -> Bool {
    if let detail = session.subcategory {
      let bytes = detail.utf8
      guard !bytes.isEmpty, bytes.prefix(33).count <= 32,
        bytes.allSatisfy({ (97...122).contains($0) })
      else { return false }
    }
    let start = session.start.timeIntervalSinceReferenceDate
    let end = session.end.timeIntervalSinceReferenceDate
    return start >= Self.firstSupportedDay && end <= Self.afterLastSupportedDay && start < end
      && validAppField(session.appID) && validAppField(session.appName)
      && (session.deviceName.map(validAppField) ?? true)
      && session.category.utf8.prefix(14).count <= 13 && Self.categories.contains(session.category)
  }

  private func validAppField(_ value: String) -> Bool {
    let bytes = value.utf8
    let byteCount = bytes.prefix(Self.maximumAppFieldBytes + 1).count
    return byteCount > 0 && byteCount <= Self.maximumAppFieldBytes && !bytes.contains(0)
  }

  private func open(createIfMissing: Bool = false) throws -> (OpaquePointer, Keys)? {
    if let db, let keys { return (db, keys) }
    guard createIfMissing || url != nil else { return nil }

    let path = url?.path ?? ":memory:"
    let file: stat?
    let existing: Metadata?
    if let url {
      guard url.isFileURL else { throw Failure.database(SQLITE_CANTOPEN) }
      file = try fileInfo(path)
      if let file {
        let readOnly = try connect(path, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(readOnly) }
        existing = try metadata(on: readOnly)
        if existing == nil {
          guard file.st_size == 0 else { throw Failure.unsupportedSchema }
          guard createIfMissing else { return nil }
        }
      } else {
        for suffix in ["-wal", "-journal", "-shm"] where try fileInfo(path + suffix) != nil {
          throw Failure.database(SQLITE_CANTOPEN)
        }
        guard createIfMissing else { return nil }
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        existing = nil
      }
    } else {
      file = nil
      existing = nil
    }

    let master: SymmetricKey
    if url == nil {
      master = SymmetricKey(size: .bits256)
    } else if let keyProvider {
      master = try keyProvider()
    } else {
      master = try ActivityKeys.localKey(createIfMissing: file == nil)
    }
    guard master.bitCount >= 128 else { throw Failure.authentication }

    let verified = try existing.map { try $0.unlock(with: master) }
    let flags = SQLITE_OPEN_READWRITE | (file == nil ? SQLITE_OPEN_CREATE : 0)
    let handle = try connect(path, flags: flags)
    do {
      let unlocked: Keys
      if let existing, let verified {
        guard try metadata(on: handle) == existing else { throw Failure.authentication }
        unlocked = verified
      } else {
        try execute("BEGIN IMMEDIATE", on: handle)
        do {
          if let current = try metadata(on: handle) {
            unlocked = try current.unlock(with: master)
          } else {
            unlocked = try initialize(handle, master: master)
          }
          try execute("COMMIT", on: handle)
        } catch {
          sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
          throw error
        }
        try execute("PRAGMA journal_mode=WAL", on: handle)
      }
      db = handle
      keys = unlocked
      return (handle, unlocked)
    } catch {
      sqlite3_close(handle)
      throw error
    }
  }

  private func fileInfo(_ path: String) throws -> stat? {
    var info = stat()
    if lstat(path, &info) == 0 { return info }
    guard errno == ENOENT else { throw Failure.database(SQLITE_CANTOPEN) }
    return nil
  }

  private func connect(_ path: String, flags: Int32) throws -> OpaquePointer {
    var handle: OpaquePointer?
    let status = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
    guard status == SQLITE_OK, let handle else {
      sqlite3_close(handle)
      throw Failure.database(status)
    }
    do {
      try check(sqlite3_busy_timeout(handle, 1000))
      return handle
    } catch {
      sqlite3_close(handle)
      throw error
    }
  }

  private func metadata(on handle: OpaquePointer) throws -> Metadata? {
    var tables: Set<String> = []
    try scan(
      "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT GLOB 'sqlite_*'",
      on: handle
    ) { query in
      guard let name = sqlite3_column_text(query, 0) else { throw Failure.unsupportedSchema }
      tables.insert(String(cString: name))
      guard tables.count <= 3 else { throw Failure.unsupportedSchema }
    }
    if tables.isEmpty { return nil }
    guard tables == ["activity_metadata", "activity_records", "activity_ranges"] else {
      throw Failure.unsupportedSchema
    }
    return try statement("SELECT salt, key_check FROM activity_metadata", on: handle) { query in
      guard sqlite3_step(query) == SQLITE_ROW else { throw Failure.authentication }
      let salt = try token(at: 0, in: query)
      let check = try blob(at: 1, in: query, length: Self.sealedOverhead...Self.sealedOverhead)
      guard sqlite3_step(query) == SQLITE_DONE else { throw Failure.authentication }
      return Metadata(salt: salt, keyCheck: check)
    }
  }

  private func initialize(_ handle: OpaquePointer, master: SymmetricKey) throws -> Keys {
    let schema = """
      CREATE TABLE activity_metadata (
        salt BLOB NOT NULL CHECK (length(salt) = 32),
        key_check BLOB NOT NULL CHECK (length(key_check) = 28)
      );
      CREATE TABLE activity_records (
        record_key BLOB PRIMARY KEY NOT NULL CHECK (length(record_key) = 32),
        device_key BLOB NOT NULL CHECK (length(device_key) = 32),
        day_key BLOB NOT NULL CHECK (length(day_key) = 32),
        ciphertext BLOB NOT NULL CHECK (length(ciphertext) BETWEEN 28 AND 16384)
      ) WITHOUT ROWID;
      CREATE INDEX activity_records_device_day ON activity_records (device_key, day_key);
      CREATE TABLE activity_ranges (
        bucket BLOB NOT NULL CHECK (length(bucket) = 32),
        device_key BLOB NOT NULL CHECK (length(device_key) = 32),
        record_key BLOB NOT NULL CHECK (length(record_key) = 32),
        PRIMARY KEY (bucket, device_key, record_key)
      ) WITHOUT ROWID;
      """
    let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let keys = Keys(master: master, salt: salt)
    let keyCheck = try keys.seal(Data(), authenticating: Metadata.aad)
    try execute(schema, on: handle)
    let insertMetadata = "INSERT INTO activity_metadata (salt, key_check) VALUES (?, ?)"
    try statement(insertMetadata, on: handle) { query in
      try bind(salt, at: 1, in: query)
      try bind(keyCheck, at: 2, in: query)
      try check(sqlite3_step(query), expected: SQLITE_DONE)
    }
    return keys
  }

  private func execute(_ sql: String, on handle: OpaquePointer) throws {
    try check(sqlite3_exec(handle, sql, nil, nil, nil))
  }

  private func statement<T>(
    _ sql: String, on handle: OpaquePointer, body: (OpaquePointer) throws -> T
  ) throws -> T {
    var query: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &query, nil))
    guard let query else { throw Failure.database(SQLITE_ERROR) }
    defer { sqlite3_finalize(query) }
    return try body(query)
  }

  private func scan(
    _ sql: String, on handle: OpaquePointer, bind: (OpaquePointer) throws -> Void = { _ in },
    visit: (OpaquePointer) throws -> Void
  ) throws {
    try statement(sql, on: handle) { query in
      try Task.checkCancellation()
      try bind(query)
      var status = sqlite3_step(query)
      while status == SQLITE_ROW {
        try Task.checkCancellation()
        try visit(query)
        status = sqlite3_step(query)
      }
      try check(status, expected: SQLITE_DONE)
    }
  }

  private func decodeSession(
    _ query: OpaquePointer, keys: Keys, decoder: JSONDecoder = JSONDecoder()
  ) throws -> ActivitySession {
    let indexes = RecordIndexes(
      record: try token(at: 0, in: query), device: try token(at: 1, in: query),
      day: try token(at: 2, in: query))
    let ciphertext = try blob(
      at: 3, in: query, length: Self.sealedOverhead...Self.maximumCiphertextBytes)
    let plaintext = try keys.unseal(ciphertext, authenticating: indexes.aad)
    guard let session = try? decoder.decode(ActivitySession.self, from: plaintext),
      validSession(session), keys.indexes(for: session) == indexes
    else { throw Failure.authentication }
    return session
  }

  private func token(at index: Int32, in query: OpaquePointer) throws -> Data {
    try blob(at: index, in: query, length: Self.tokenBytes...Self.tokenBytes)
  }

  private func blob(
    at index: Int32, in query: OpaquePointer, length: ClosedRange<Int>
  ) throws -> Data {
    guard sqlite3_column_type(query, index) == SQLITE_BLOB else { throw Failure.authentication }
    let count = Int(sqlite3_column_bytes(query, index))
    guard length.contains(count), let bytes = sqlite3_column_blob(query, index) else {
      throw Failure.authentication
    }
    return Data(bytes: bytes, count: count)
  }

  private func bind(_ value: Data, at index: Int32, in query: OpaquePointer) throws {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let status = value.withUnsafeBytes {
      sqlite3_bind_blob(query, index, $0.baseAddress, Int32($0.count), transient)
    }
    try check(status)
  }

  private func check(_ status: Int32, expected: Int32 = SQLITE_OK) throws {
    guard status == expected else { throw Failure.database(status) }
  }

  private struct Metadata: Equatable {
    static let aad = Data("XStats.ActivityStore.v1.key-check".utf8)
    let salt: Data
    let keyCheck: Data

    func unlock(with master: SymmetricKey) throws -> Keys {
      let keys = Keys(master: master, salt: salt)
      guard try keys.unseal(keyCheck, authenticating: Self.aad).isEmpty else {
        throw Failure.authentication
      }
      return keys
    }
  }

  private struct RecordIndexes: Equatable {
    let record: Data
    let device: Data
    let day: Data

    var aad: Data { Data("XStats.ActivityStore.v1.record".utf8) + record + device + day }
  }

  private struct Keys {
    let encryption: SymmetricKey
    let indexing: SymmetricKey

    init(master: SymmetricKey, salt: Data) {
      encryption = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: master, salt: salt, info: Data("XStats.ActivityStore.v1.encryption".utf8),
        outputByteCount: 32)
      indexing = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: master, salt: salt, info: Data("XStats.ActivityStore.v1.indexes".utf8),
        outputByteCount: 32)
    }

    func indexes(for session: ActivitySession) -> RecordIndexes {
      RecordIndexes(
        record: token("record", session.id.uuidString), device: device(session.deviceID),
        day: startDay(ActivityStore.dayIndex(session.start), deviceID: session.deviceID))
    }

    func device(_ id: UUID) -> Data {
      token("device", id.uuidString)
    }

    func startDay(_ day: Int, deviceID: UUID) -> Data {
      token("start-day", "\(deviceID.uuidString):\(day)")
    }

    func token(_ domain: String, _ value: String) -> Data {
      Data(HMAC<SHA256>.authenticationCode(for: Data("\(domain):\(value)".utf8), using: indexing))
    }

    func seal(_ plaintext: Data, authenticating aad: Data) throws -> Data {
      let box = try AES.GCM.seal(plaintext, using: encryption, authenticating: aad)
      guard let combined = box.combined else { throw Failure.authentication }
      return combined
    }

    func unseal(_ ciphertext: Data, authenticating aad: Data) throws -> Data {
      do {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: encryption, authenticating: aad)
      } catch {
        throw Failure.authentication
      }
    }
  }
}
