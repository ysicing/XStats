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
  @ObservationIgnored private(set) var database: HistoryDatabase?
  @ObservationIgnored private var accumulator = HistoryAccumulator()
  @ObservationIgnored private var lastPrune = Date.distantPast
  @ObservationIgnored private var pendingWrite: Task<Void, Never>?

  init(settings: AppSettings, databaseURL: URL? = HistoryDatabase.defaultURL) {
    self.settings = settings
    if let databaseURL {
      database = try? HistoryDatabase(url: databaseURL)
    }
  }

  /// 每次采样后调用；只记录这次快照里真实采到的指标
  func record(_ snapshot: MetricsSnapshot) {
    guard settings.historyEnabled, database != nil else { return }
    let battery = settings.isModuleEnabled(.battery) ? snapshot.battery?.level : nil
    // 关闭电池监测后仍读取基础电量，但不能因此每分钟写入一条空历史。
    guard
      snapshot.cpu != nil || snapshot.memory != nil || snapshot.network != nil
        || snapshot.gpu != nil || snapshot.sensors?.temperature(.cpu) != nil
        || snapshot.power?.system != nil || battery != nil
    else { return }
    let finished = accumulator.add(
      date: snapshot.date,
      cpu: snapshot.cpu?.total,
      memory: snapshot.memory?.usedFraction,
      pressure: snapshot.memory?.pressure.rawValue,
      download: snapshot.network?.downloadBytesPerSecond,
      upload: snapshot.network?.uploadBytesPerSecond,
      gpu: snapshot.gpu?.utilization,
      temperature: snapshot.sensors?.temperature(.cpu)?.maximum,
      power: snapshot.power?.system,
      battery: battery)
    guard let finished else { return }
    let now = Date()
    let prune = now.timeIntervalSince(lastPrune) > 60 * 60
    if prune { lastPrune = now }
    enqueueWrite(
      finished, pruneBefore: prune ? now.addingTimeInterval(-HistoryDatabase.retention) : nil)
  }

  /// 暂停采样（睡眠、锁屏）或退出前排队写入当前这一分钟。
  func flush() {
    guard let record = accumulator.flush() else { return }
    enqueueWrite(record)
  }

  /// 停止新增采样后调用；等待当前分钟及此前排队的写入完成，失败由数据库记录日志。
  func flushAndWait() async {
    flush()
    await pendingWrite?.value
  }

  private func enqueueWrite(_ record: HistoryRecord, pruneBefore: Date? = nil) {
    guard let database else { return }
    let previous = pendingWrite
    pendingWrite = Task {
      await previous?.value
      await database.insert(record)
      if let pruneBefore { await database.prune(before: pruneBefore) }
    }
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
    accumulator = HistoryAccumulator()
    guard let database else { return }
    let previous = pendingWrite
    pendingWrite = Task {
      await previous?.value
      await database.clear()
      load()
    }
  }
}
