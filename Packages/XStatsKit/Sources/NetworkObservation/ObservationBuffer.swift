// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 锁内只做有界队列操作，不访问磁盘或等待 IPC；竞争不能悄悄丢失观察事件。
public final class ObservationBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var journal = ConnectionJournal()
  private var active: [UUID: ObservedConnection] = [:]
  private var captureDropped: Int64 = 0
  private var sealed = false
  private var observationID = UUID()
  private var leaseUntil: TimeInterval = 0
  private var diagnosticsUntil: TimeInterval = 0
  private var diagnosticsToken = UUID().uuidString
  private var newFlowCallbacks: UInt64 = 0

  public init() {}

  /// 租约检查只有常量时间临界区；不把锁竞争误认为观察停止。
  public func trafficDemand(
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Bool? {
    lock.lock()
    defer { lock.unlock() }
    return now < leaseUntil
  }

  public func isObserving(
    now: TimeInterval = ProcessInfo.processInfo.systemUptime, countNewFlow: Bool = false
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    // 诊断默认关闭且不续租，不增加轮询或连接内容读取。
    if diagnosticsUntil > 0, now >= diagnosticsUntil { diagnosticsUntil = 0 }
    if countNewFlow, diagnosticsUntil > 0 { newFlowCallbacks &+= 1 }
    return now < leaseUntil
  }

  /// 显式窗口最多 30 秒；零秒关闭窗口并保留上一 token 和计数，便于比较差值。
  /// 窗口过期按回调/RPC 惰性关闭，不增加定时器，也不改变观察租约或历史。
  public func flowDiagnostics(
    windowSeconds: Double,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> FlowDiagnosticsDTO {
    lock.lock()
    defer { lock.unlock() }
    if windowSeconds.isFinite, windowSeconds > 0 {
      diagnosticsToken = UUID().uuidString
      newFlowCallbacks = 0
      diagnosticsUntil = now + min(windowSeconds, 30)
    } else {
      diagnosticsUntil = 0
    }
    return .init(token: diagnosticsToken, newFlowCallbacks: newFlowCallbacks)
  }

  @discardableResult public func record(
    _ event: ObservedConnection, now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard now < leaseUntil else { return false }
    guard active.count < ObservationLimits.captureCount else {
      captureDropped += 1
      return false
    }
    var event = event
    event.executablePath = boundedMetadata(event.executablePath, bytes: 768)
    event.hostname = event.hostname.map { boundedMetadata($0, bytes: 252) }
    event.address = event.address.map { boundedMetadata($0, bytes: 125) }
    event.traffic = .init(
      id: event.id, timestamp: event.timestamp, receivedBytes: 0, sentBytes: 0)
    event.traffic?.observationID = observationID
    journal.append(event, metadataIsBounded: true)
    active[event.id] = event
    return true
  }

  /// 每个统计区间进入待确认增量队列，数据库成功写入后才回收；不能覆盖尚未落库的区间。
  public func updateTraffic(
    _ id: UUID, receivedBytes: UInt64, sentBytes: UInt64, at date: Date = Date(),
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard now < leaseUntil, var record = active[id] else { return }
    record.traffic = .init(
      id: id, timestamp: date, receivedBytes: receivedBytes, sentBytes: sentBytes)
    record.traffic?.observationID = observationID
    active[id] = record
    journal.append(record, metadataIsBounded: true)
  }

  /// 结束报告无数据内容。即使租约刚过期也移除已有标识，避免保留虚假的活动连接。
  public func close(
    _ id: UUID, receivedBytes: UInt64? = nil, sentBytes: UInt64? = nil,
    at date: Date = Date(), now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard var record = active.removeValue(forKey: id) else { return }
    guard !sealed else { return }
    record.closedAt = date
    if now < leaseUntil, let receivedBytes, let sentBytes {
      record.traffic = .init(
        id: id, timestamp: date, receivedBytes: receivedBytes, sentBytes: sentBytes)
      record.traffic?.observationID = observationID
    } else {
      record.traffic = nil
    }
    journal.append(record, metadataIsBounded: true)
  }

  public func read(
    after cursor: Int64, epoch: String,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime, renewLease: Bool = true,
    legacy: Bool = false
  ) -> ObservationBatch {
    lock.lock()
    defer { lock.unlock() }
    if renewLease { journal.prepare() }
    if renewLease && now >= leaseUntil { observationID = UUID() }
    sealed = !renewLease
    leaseUntil = renewLease ? now + ObservationLimits.leaseSeconds : 0
    journal.acknowledge(through: cursor, epoch: epoch)
    var batch = journal.batch(after: cursor, epoch: epoch)
    batch.trafficVersion = NetworkObservationProtocol.trafficVersion
    batch.captureDropped = captureDropped
    if legacy {
      batch.protocolVersion = NetworkObservationProtocol.controlVersion
      // 仅旧接口按需生成窗口，不额外常驻保存一份连接历史。
      batch.activeIDs = Array(active.keys.prefix(ObservationLimits.displayCount))
      batch.trafficVersion = nil
    }
    return batch
  }

  /// 读取端暂停或切换时只停止记录新连接；已观察的活动连接继续接收结束报告，
  /// 恢复后同一游标接着读取，切换标签或锁屏不会让仍在进行的连接从列表中消失。
  public func endLease() {
    lock.lock()
    defer { lock.unlock() }
    leaseUntil = 0
    for id in active.keys { active[id]?.traffic = nil }
  }

  /// 过滤器停止时清空全部状态。
  public func stop() {
    lock.lock()
    defer { lock.unlock() }
    leaseUntil = 0
    journal.clear()
    active.removeAll(keepingCapacity: true)
    captureDropped = 0
    sealed = false
  }
}
