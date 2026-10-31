// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NetworkObservation

struct NetworkTrafficPoint: Identifiable, Sendable {
  var id: Date { date }
  let date: Date
  var receivedBytesPerSecond: Double?
  var sentBytesPerSecond: Double?
  var segment: Int
}

/// 仅供离线演示和截图生成曲线；真实监视使用 NetworkHistoryStore，不在此存储历史。
struct NetworkTrafficHistory {
  static let maximumSamples = 8192
  private struct Baseline {
    let record: ObservedConnection
    let snapshot: ConnectionTrafficSnapshot
  }
  private struct Sample {
    let record: ObservedConnection
    let start: Date
    let end: Date
    let received: Double
    let sent: Double
    let segment: Int
  }
  private var baselines: [UUID: Baseline] = [:]
  private var samples: [Sample] = []
  private var segment = 0
  private var minimumTimestamp = Date.distantPast
  private var nextPruneAt = Date.distantPast
  var sampleCount: Int { samples.count }

  mutating func observe(_ record: ObservedConnection, snapshot: ConnectionTrafficSnapshot) {
    guard snapshot.timestamp.timeIntervalSince1970.isFinite,
      snapshot.timestamp >= minimumTimestamp
    else { return }
    if let previous = baselines[record.id] {
      guard snapshot.timestamp > previous.snapshot.timestamp else { return }
      let duration = snapshot.timestamp.timeIntervalSince(previous.snapshot.timestamp)
      if duration <= 15,
        snapshot.receivedBytes >= previous.snapshot.receivedBytes,
        snapshot.sentBytes >= previous.snapshot.sentBytes
      {
        samples.append(
          Sample(
            record: record, start: previous.snapshot.timestamp, end: snapshot.timestamp,
            received: Double(snapshot.receivedBytes - previous.snapshot.receivedBytes),
            sent: Double(snapshot.sentBytes - previous.snapshot.sentBytes), segment: segment))
      }
    }
    baselines[record.id] = Baseline(record: record, snapshot: snapshot)
    if baselines.count > ObservationLimits.displayCount {
      let oldest = baselines.min { $0.value.snapshot.timestamp < $1.value.snapshot.timestamp }?.key
      if let oldest { baselines.removeValue(forKey: oldest) }
    }
    // 同一批可包含数百条流；按时间统一清理，不能为每个报告重复扫描整个窗口。
    if snapshot.timestamp >= nextPruneAt {
      samples.removeAll { $0.end < snapshot.timestamp.addingTimeInterval(-900) }
      nextPruneAt = snapshot.timestamp.addingTimeInterval(5)
    }
    if samples.count > Self.maximumSamples {
      samples.removeFirst(samples.count - Self.maximumSamples)
    }
  }

  mutating func accept(_ batch: ObservationBatch, records: [ObservedConnection]) {
    for record in batch.events {
      if let snapshot = record.traffic { observe(record, snapshot: snapshot) }
      if record.closedAt != nil { baselines.removeValue(forKey: record.id) }
    }
    let metadata = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    for snapshot in batch.traffic ?? [] {
      if let record = metadata[snapshot.id] { observe(record, snapshot: snapshot) }
    }
    // activeIDs 是读取时的快照，关闭事件可能还在下一批；基线由关闭事件和容量上限回收。
  }

  mutating func pause(at date: Date = Date()) {
    baselines.removeAll(keepingCapacity: true)
    minimumTimestamp = date
    segment &+= 1
  }

  mutating func clear() {
    baselines.removeAll()
    samples.removeAll()
    nextPruneAt = .distantPast
    segment &+= 1
  }

  /// 以5秒时间桶绘制报告区间的平均速率；没有报告的桶保持缺口，不补零。
  func points(
    interval: TimeInterval, matching: (ObservedConnection) -> Bool, now: Date = Date()
  ) -> [NetworkTrafficPoint] {
    let step = 5.0
    let end = ceil(now.timeIntervalSince1970 / step) * step
    let count = max(1, min(180, Int(interval / step)))
    let start = end - Double(count) * step
    var points = (0..<count).map { index in
      NetworkTrafficPoint(
        date: Date(timeIntervalSince1970: start + Double(index + 1) * step),
        receivedBytesPerSecond: nil, sentBytesPerSecond: nil, segment: segment)
    }
    for sample in samples
    where sample.end.timeIntervalSince1970 > start
      && sample.start.timeIntervalSince1970 < end && matching(sample.record)
    {
      let lower = max(start, sample.start.timeIntervalSince1970)
      let upper = min(end, sample.end.timeIntervalSince1970)
      guard upper > lower else { continue }
      let duration = sample.end.timeIntervalSince(sample.start)
      let first = max(0, Int((lower - start) / step))
      let last = min(count - 1, Int(ceil((upper - start) / step)) - 1)
      guard first <= last else { continue }
      for index in first...last {
        let bucketStart = start + Double(index) * step
        let overlap = min(upper, bucketStart + step) - max(lower, bucketStart)
        // 同一个时间桶里先后跨过暂停时只展示恢复段，不能用一条线接回暂停前。
        if points[index].receivedBytesPerSecond != nil && points[index].segment != sample.segment {
          points[index].receivedBytesPerSecond = nil
          points[index].sentBytesPerSecond = nil
        }
        points[index].receivedBytesPerSecond =
          (points[index].receivedBytesPerSecond ?? 0) + sample.received / duration * overlap / step
        points[index].sentBytesPerSecond =
          (points[index].sentBytesPerSecond ?? 0) + sample.sent / duration * overlap / step
        points[index].segment = sample.segment
      }
    }
    // Charts 会忽略 nil 点；为每段连续有效时间分配 series，防止跨空白桶连线。
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
}
