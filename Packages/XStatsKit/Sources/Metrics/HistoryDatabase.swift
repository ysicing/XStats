import Foundation
import Localization
import SQLite3

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

    public init(minute: Int, cpu: Double? = nil, cpuMax: Double? = nil, memory: Double? = nil, pressure: Int? = nil,
                download: Double? = nil, upload: Double? = nil, gpu: Double? = nil, temperature: Double? = nil, power: Double? = nil,
                battery: Double? = nil) {
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

/// 本机 SQLite 历史库（~/Library/Application Support/XStats/history.sqlite），只存每分钟汇总，7 天约 1 万行
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

    public init(url: URL = HistoryDatabase.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
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
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            db = nil
            throw Error.open(message)
        }
        // 旧库没有 battery 列：加上；新库已经有，这句报“列已存在”，忽略
        sqlite3_exec(handle, "ALTER TABLE samples ADD COLUMN battery REAL", nil, nil, nil)
    }

    deinit {
        sqlite3_close(db)
    }

    public func insert(_ record: HistoryRecord) {
        let sql = """
        INSERT OR REPLACE INTO samples (minute, cpu, cpu_max, memory, pressure, download, upload, gpu, temperature, power, battery)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(record.minute))
        let values: [Double?] = [record.cpu, record.cpuMax, record.memory, record.pressure.map(Double.init),
                                 record.download, record.upload, record.gpu, record.temperature, record.power, record.battery]
        for (index, value) in values.enumerated() {
            let position = Int32(index + 2)
            if let value, value.isFinite {
                sqlite3_bind_double(statement, position, value)
            } else {
                sqlite3_bind_null(statement, position)
            }
        }
        sqlite3_step(statement)
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
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(size))
        sqlite3_bind_int64(statement, 2, Int64(size))
        sqlite3_bind_int64(statement, 3, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 4, Int64(end.timeIntervalSince1970))

        func double(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }
        var points: [HistoryPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            points.append(HistoryPoint(date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                                       cpu: double(1), cpuMax: double(2), memory: double(3), pressure: double(4).map { Int($0) },
                                       download: double(5), upload: double(6), gpu: double(7), temperature: double(8), power: double(9),
                                       battery: double(10)))
        }
        return points
    }

    public func prune(before date: Date) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM samples WHERE minute < ?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970))
        sqlite3_step(statement)
    }

    public func clear() {
        sqlite3_exec(db, "DELETE FROM samples; VACUUM;", nil, nil, nil)
    }

    public func count() -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }
}

/// 把一分钟内的多次采样合成一条记录
public struct HistoryAccumulator: Sendable {
    private var minute: Int?
    private var sums: [String: (total: Double, count: Int)] = [:]
    private var maxima: [String: Double] = [:]

    public init() {}

    /// 加入一次采样；跨到下一分钟时返回上一分钟的记录
    public mutating func add(date: Date, cpu: Double?, memory: Double?, pressure: Int?, download: Double?, upload: Double?,
                             gpu: Double?, temperature: Double?, power: Double?, battery: Double? = nil) -> HistoryRecord? {
        let current = Int(date.timeIntervalSince1970) / 60 * 60
        var finished: HistoryRecord?
        if let minute, minute != current {
            finished = record(for: minute)
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
        average("cpu", cpu); peak("cpu", cpu)
        average("memory", memory)
        peak("pressure", pressure.map(Double.init))
        average("download", download)
        average("upload", upload)
        average("gpu", gpu)
        peak("temperature", temperature)
        average("power", power)
        average("battery", battery)
        return finished
    }

    /// 退出或暂停时写入当前这一分钟
    public mutating func flush() -> HistoryRecord? {
        guard let minute, !sums.isEmpty || !maxima.isEmpty else { return nil }
        defer {
            self.minute = nil
            sums = [:]
            maxima = [:]
        }
        return record(for: minute)
    }

    private func record(for minute: Int) -> HistoryRecord {
        func mean(_ key: String) -> Double? { sums[key].map { $0.total / Double($0.count) } }
        return HistoryRecord(minute: minute, cpu: mean("cpu"), cpuMax: maxima["cpu"], memory: mean("memory"),
                             pressure: maxima["pressure"].map { Int($0) }, download: mean("download"), upload: mean("upload"),
                             gpu: mean("gpu"), temperature: maxima["temperature"], power: mean("power"), battery: mean("battery"))
    }
}
