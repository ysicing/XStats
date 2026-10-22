import Foundation
import Localization
import SQLite3
import OSLog

/// 每分钟一条的历史记录；没有采集到的指标为 nil
public struct HistoryRecord: Sendable, Equatable {
  /// Unix 时间戳按分钟取整
  public var minute: Int
  public var cpu: Double?
  public var cpuMax: Double?
  public var memory: Double?
  /// 内存压力最高档：1 正常、2 偏高、4 严重
  public var pressure: Int?
  public var download: Double?
  public var upload: Double?
  public var gpu: Double?
  public var temperature: Double?
  public var power: Double?
  /// 电池电量 0...1；没有电池或没在看电池时为空
  public var battery: Double?

  public init(
    minute: Int, cpu: Double? = nil, cpuMax: Double? = nil, memory: Double? = nil,
    pressure: Int? = nil,
    download: Double? = nil, upload: Double? = nil, gpu: Double? = nil, temperature: Double? = nil,
    power: Double? = nil,
    battery: Double? = nil
  ) {
    self.minute = minute
    self.cpu = cpu
    self.cpuMax = cpuMax
    self.memory = memory
    self.pressure = pressure
    self.download = download
    self.upload = upload
    self.gpu = gpu
    self.temperature = temperature
    self.power = power
    self.battery = battery
  }
}

/// 查询结果：一个时间桶内的平均值与峰值
public struct HistoryPoint: Sendable, Equatable {
  public var date: Date
  public var cpu: Double?
  public var cpuMax: Double?
  public var memory: Double?
  public var pressure: Int?
  public var download: Double?
  public var upload: Double?
  public var gpu: Double?
  public var temperature: Double?
  public var power: Double?
  public var battery: Double?
}

/// 本机 SQLite 历史库（~/Library/Application Support/XStats/history.sqlite）：每分钟指标汇总保留 8 天（约 1 万行）
public actor HistoryDatabase {
  public enum Error: Swift.Error {
    case open(String)
  }

  public static let retention: TimeInterval = 8 * 24 * 60 * 60

  public static var defaultURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("XStats/history.sqlite")
  }

  nonisolated(unsafe) private var db: OpaquePointer?
  private static let log = Logger(subsystem: "work.12306.xstats", category: "history")
  private var failures: [String: Int32] = [:]

  /// 同一操作的相同错误只记录一次；只记录 SQLite 状态码，不暴露路径或数据。
  private func succeeded(_ code: Int32, operation: String) -> Bool {
    if code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW {
      if failures.removeValue(forKey: operation) != nil {
        Self.log.notice("历史数据库操作恢复：\(operation, privacy: .public)")
      }
      return true
    }
    if failures[operation] != code {
      Self.log.error("历史数据库操作失败：\(operation, privacy: .public)，SQLite \(code)")
      failures[operation] = code
    }
    return false
  }

  public init(url: URL = HistoryDatabase.defaultURL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? tr("无法打开")
      sqlite3_close(handle)
      throw Error.open(message)
    }
    db = handle
    let schema = """
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS samples (
          minute INTEGER PRIMARY KEY,
          cpu REAL, cpu_max REAL, memory REAL, pressure INTEGER,
          download REAL, upload REAL, gpu REAL, temperature REAL, power REAL, battery REAL
      );
      """
    let schemaResult = sqlite3_exec(handle, schema, nil, nil, nil)
    guard schemaResult == SQLITE_OK else {
      Self.log.error("历史数据库建表失败：SQLite \(schemaResult)")
      let message = String(cString: sqlite3_errmsg(handle))
      sqlite3_close(handle)
      db = nil
      throw Error.open(message)
    }
    // 只迁移缺失列；真实迁移失败必须在打开阶段报告，不能留下一个无法写入的库。
    if sqlite3_table_column_metadata(handle, nil, "samples", "battery", nil, nil, nil, nil, nil)
      != SQLITE_OK
    {
      let migrationResult = sqlite3_exec(
        handle, "ALTER TABLE samples ADD COLUMN battery REAL", nil, nil, nil)
      guard migrationResult == SQLITE_OK else {
        Self.log.error("历史数据库迁移失败：SQLite \(migrationResult)")
        let message = String(cString: sqlite3_errmsg(handle))
        sqlite3_close(handle)
        db = nil
        throw Error.open(message)
      }
    }
  }

  deinit {
    sqlite3_close(db)
  }

  /// 返回是否成功写入；失败按状态变化记录日志，不将失败伪装成已保存。
  @discardableResult public func insert(_ record: HistoryRecord) -> Bool {
    let sql = """
      INSERT OR REPLACE INTO samples (minute, cpu, cpu_max, memory, pressure, download, upload, gpu, temperature, power, battery)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """
    var statement: OpaquePointer?
    guard succeeded(sqlite3_prepare_v2(db, sql, -1, &statement, nil), operation: "insert.prepare")
    else { return false }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, Int64(record.minute))
    let values: [Double?] = [
      record.cpu, record.cpuMax, record.memory, record.pressure.map(Double.init),
      record.download, record.upload, record.gpu, record.temperature, record.power, record.battery,
    ]
    for (index, value) in values.enumerated() {
      let position = Int32(index + 2)
      if let value, value.isFinite {
        sqlite3_bind_double(statement, position, value)
      } else {
        sqlite3_bind_null(statement, position)
      }
    }
    return succeeded(sqlite3_step(statement), operation: "insert")
  }

  /// 按 bucket 秒汇总：平均值取平均，CPU 峰值、内存压力、温度取最大
  public func query(from start: Date, to end: Date, bucket: Int) -> [HistoryPoint] {
    let size = max(60, bucket)
    let sql = """
      SELECT (minute / ?) * ? AS slot, AVG(cpu), MAX(cpu_max), AVG(memory), MAX(pressure),
             AVG(download), AVG(upload), AVG(gpu), MAX(temperature), AVG(power), AVG(battery)
      FROM samples WHERE minute >= ? AND minute < ?
      GROUP BY slot ORDER BY slot
      """
    var statement: OpaquePointer?
    guard succeeded(sqlite3_prepare_v2(db, sql, -1, &statement, nil), operation: "query.prepare")
    else { return [] }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, Int64(size))
    sqlite3_bind_int64(statement, 2, Int64(size))
    sqlite3_bind_int64(statement, 3, Int64(start.timeIntervalSince1970))
    sqlite3_bind_int64(statement, 4, Int64(end.timeIntervalSince1970))

    func double(_ column: Int32) -> Double? {
      sqlite3_column_type(statement, column) == SQLITE_NULL
        ? nil : sqlite3_column_double(statement, column)
    }
    var points: [HistoryPoint] = []
    var code = sqlite3_step(statement)
    while code == SQLITE_ROW {
      points.append(
        HistoryPoint(
          date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
          cpu: double(1), cpuMax: double(2), memory: double(3), pressure: double(4).map { Int($0) },
          download: double(5), upload: double(6), gpu: double(7), temperature: double(8),
          power: double(9),
          battery: double(10)))
      code = sqlite3_step(statement)
    }
    return succeeded(code, operation: "query") ? points : []
  }

  public func prune(before date: Date) {
    var statement: OpaquePointer?
    guard
      succeeded(
        sqlite3_prepare_v2(db, "DELETE FROM samples WHERE minute < ?", -1, &statement, nil),
        operation: "prune.prepare")
    else { return }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970))
    _ = succeeded(sqlite3_step(statement), operation: "prune")
  }

  public func clear() {
    guard
      succeeded(
        sqlite3_exec(db, "BEGIN IMMEDIATE; DELETE FROM samples; COMMIT;", nil, nil, nil),
        operation: "clear")
    else {
      sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
      return
    }
    _ = succeeded(sqlite3_exec(db, "VACUUM;", nil, nil, nil), operation: "vacuum")
  }

  public func count() -> Int {
    var statement: OpaquePointer?
    guard
      succeeded(
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples", -1, &statement, nil),
        operation: "count.prepare")
    else { return 0 }
    defer { sqlite3_finalize(statement) }
    let code = sqlite3_step(statement)
    return succeeded(code, operation: "count") && code == SQLITE_ROW
      ? Int(sqlite3_column_int64(statement, 0)) : 0
  }
}

/// 把一分钟内的多次采样合成一条记录
public struct HistoryAccumulator: Sendable {
  private var minute: Int?
  private var sums: [String: (total: Double, count: Int)] = [:]
  private var maxima: [String: Double] = [:]
  private var needsFlush = false

  public init() {}

  /// 加入一次采样；跨分钟时返回上一分钟尚未刷新的累计记录。
  public mutating func add(
    date: Date, cpu: Double?, memory: Double?, pressure: Int?, download: Double?, upload: Double?,
    gpu: Double?, temperature: Double?, power: Double?, battery: Double? = nil
  ) -> HistoryRecord? {
    let current = Int(date.timeIntervalSince1970) / 60 * 60
    var finished: HistoryRecord?
    if let minute, minute != current {
      if needsFlush { finished = record(for: minute) }
      sums = [:]
      maxima = [:]
    }
    minute = current
    func average(_ key: String, _ value: Double?) {
      guard let value, value.isFinite else { return }
      let entry = sums[key] ?? (0, 0)
      sums[key] = (entry.total + value, entry.count + 1)
    }
    func peak(_ key: String, _ value: Double?) {
      guard let value, value.isFinite else { return }
      maxima[key] = max(maxima[key] ?? value, value)
    }
    average("cpu", cpu)
    peak("cpu", cpu)
    average("memory", memory)
    peak("pressure", pressure.map(Double.init))
    average("download", download)
    average("upload", upload)
    average("gpu", gpu)
    peak("temperature", temperature)
    average("power", power)
    average("battery", battery)
    needsFlush = true
    return finished
  }

  /// 取得当前分钟的累计快照；保留累计值，供暂停后同分钟继续采样。
  public mutating func flush() -> HistoryRecord? {
    guard needsFlush, let minute, !sums.isEmpty || !maxima.isEmpty else { return nil }
    needsFlush = false
    return record(for: minute)
  }

  private func record(for minute: Int) -> HistoryRecord {
    func mean(_ key: String) -> Double? { sums[key].map { $0.total / Double($0.count) } }
    return HistoryRecord(
      minute: minute, cpu: mean("cpu"), cpuMax: maxima["cpu"], memory: mean("memory"),
      pressure: maxima["pressure"].map { Int($0) }, download: mean("download"),
      upload: mean("upload"),
      gpu: mean("gpu"), temperature: maxima["temperature"], power: mean("power"),
      battery: mean("battery"))
  }
}
