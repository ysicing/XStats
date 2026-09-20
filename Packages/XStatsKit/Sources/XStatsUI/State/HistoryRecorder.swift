import Foundation
import Localization
import Metrics
import Observation

/// 把采样按分钟写入本机历史库，并为历史页查询数据
@MainActor
@Observable
public final class HistoryRecorder {
    public enum Range: String, CaseIterable, Identifiable, Sendable {
        case hour, day, week

        public var id: String { rawValue }

        var title: String {
            switch self {
            case .hour: tr("1 小时")
            case .day: tr("24 小时")
            case .week: tr("7 天")
            }
        }

        var duration: TimeInterval {
            switch self {
            case .hour: 60 * 60
            case .day: 24 * 60 * 60
            case .week: 7 * 24 * 60 * 60
            }
        }

        /// 每个点代表的秒数：1 小时逐分钟，24 小时每 5 分钟，7 天每 30 分钟
        var bucket: Int {
            switch self {
            case .hour: 60
            case .day: 5 * 60
            case .week: 30 * 60
            }
        }
    }

    public private(set) var points: [HistoryPoint] = []
    public private(set) var range: Range = .day
    public private(set) var rangeStart = Date()
    public private(set) var isQuerying = false
    public private(set) var recordCount = 0
    /// 电池弹窗 / 页面用的最近 24 小时电量，独立于历史页当前选的范围
    public private(set) var batteryPoints: [HistoryPoint] = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var database: HistoryDatabase?
    @ObservationIgnored private var accumulator = HistoryAccumulator()
    @ObservationIgnored private var lastPrune = Date.distantPast

    init(settings: AppSettings, databaseURL: URL? = HistoryDatabase.defaultURL) {
        self.settings = settings
        if let databaseURL {
            database = try? HistoryDatabase(url: databaseURL)
        }
    }

    /// 每次采样后调用；只记录这次快照里真实采到的指标
    func record(_ snapshot: MetricsSnapshot) {
        guard settings.historyEnabled, let database else { return }
        let finished = accumulator.add(date: snapshot.date,
                                       cpu: snapshot.cpu?.total,
                                       memory: snapshot.memory?.usedFraction,
                                       pressure: snapshot.memory?.pressure.rawValue,
                                       download: snapshot.network?.downloadBytesPerSecond,
                                       upload: snapshot.network?.uploadBytesPerSecond,
                                       gpu: snapshot.gpu?.utilization,
                                       temperature: snapshot.sensors?.temperature(.cpu)?.maximum,
                                       power: snapshot.power?.system,
                                       battery: snapshot.battery?.level)
        guard let finished else { return }
        let now = Date()
        let prune = now.timeIntervalSince(lastPrune) > 60 * 60
        if prune { lastPrune = now }
        Task {
            await database.insert(finished)
            if prune { await database.prune(before: now.addingTimeInterval(-HistoryDatabase.retention)) }
        }
    }

    /// 暂停采样（睡眠、锁屏）或退出前写入当前这一分钟
    func flush() {
        guard let database, let record = accumulator.flush() else { return }
        Task { await database.insert(record) }
    }

    func load(_ range: Range? = nil) {
        if let range { self.range = range }
        guard let database else { return }
        let range = self.range
        let end = Date()
        let start = end.addingTimeInterval(-range.duration)
        isQuerying = true
        Task {
            let points = await database.query(from: start, to: end, bucket: range.bucket)
            let count = await database.count()
            guard self.range == range else { return }
            self.points = points
            rangeStart = start
            recordCount = count
            isQuerying = false
        }
    }

    func loadBattery() {
        guard let database else { return }
        let end = Date()
        let start = end.addingTimeInterval(-Range.day.duration)
        Task {
            batteryPoints = await database.query(from: start, to: end, bucket: Range.day.bucket)
        }
    }

    func clear() {
        guard let database else { return }
        accumulator = HistoryAccumulator()
        Task {
            await database.clear()
            load()
        }
    }
}
