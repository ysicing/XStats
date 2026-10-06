// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 全部可变状态受同一锁保护；回调采用 try-lock，观察竞争不能延迟网络连接。
public final class ObservationBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var journal = ConnectionJournal()
    private var active: [UUID: ObservedConnection] = [:]
    private var activeSlots: [UUID?] = Array(repeating: nil, count: ObservationLimits.displayCount)
    private var nextActiveSlot = 0
    private var leaseUntil: TimeInterval = 0
    private var diagnosticsUntil: TimeInterval = 0
    private var diagnosticsToken = UUID().uuidString
    private var newFlowCallbacks: UInt64 = 0

    public init() {}

    public func isObserving(now: TimeInterval = ProcessInfo.processInfo.systemUptime, countNewFlow: Bool = false) -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        // 诊断默认关闭且不续租。复用网络回调已有 try-lock，竞争时不拖慢放行路径；
        // 因此诊断值是成功取得锁的回调下界，不能据单次零值声称数学上的绝对零回调。
        if diagnosticsUntil > 0, now >= diagnosticsUntil { diagnosticsUntil = 0 }
        if countNewFlow, diagnosticsUntil > 0 { newFlowCallbacks &+= 1 }
        return now < leaseUntil
    }

    /// 显式窗口最多 30 秒；零秒关闭窗口并保留上一 token 和计数，便于比较差值。
    /// 窗口过期按回调/RPC 惰性关闭，不增加定时器，也不改变观察租约或历史。
    public func flowDiagnostics(windowSeconds: Double,
                                now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> FlowDiagnosticsDTO {
        lock.lock(); defer { lock.unlock() }
        if windowSeconds.isFinite, windowSeconds > 0 {
            diagnosticsToken = UUID().uuidString
            newFlowCallbacks = 0
            diagnosticsUntil = now + min(windowSeconds, 30)
        } else { diagnosticsUntil = 0 }
        return .init(token: diagnosticsToken, newFlowCallbacks: newFlowCallbacks)
    }

    public func record(_ event: ObservedConnection, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard now < leaseUntil else { return }
        journal.append(event)
        // 与界面的最近记录窗口一致地淘汰旧连接，避免最早的长连接占满集合后吞掉后续连接。
        if let previous = activeSlots[nextActiveSlot] { active.removeValue(forKey: previous) }
        activeSlots[nextActiveSlot] = event.id
        nextActiveSlot = (nextActiveSlot + 1) % activeSlots.count
        active[event.id] = event
    }

    /// 结束报告无数据内容。即使租约刚过期也移除已有标识，避免保留虚假的活动连接。
    public func close(_ id: UUID, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard var record = active.removeValue(forKey: id) else { return }
        record.closedAt = date
        journal.append(record)
    }

    public func read(after cursor: Int64, epoch: String,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ObservationBatch {
        lock.lock(); defer { lock.unlock() }
        leaseUntil = now + ObservationLimits.leaseSeconds
        var batch = journal.batch(after: cursor, epoch: epoch)
        batch.activeIDs = Array(active.keys)
        return batch
    }

    /// 读取端暂停或切换时只停止记录新连接；已观察的活动连接继续接收结束报告，
    /// 恢复后同一游标接着读取，切换标签或锁屏不会让仍在进行的连接从列表中消失。
    public func endLease() {
        lock.lock(); defer { lock.unlock() }
        leaseUntil = 0
    }

    /// 过滤器停止时清空全部状态。
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        leaseUntil = 0
        journal.clear()
        active.removeAll(keepingCapacity: true)
        activeSlots = Array(repeating: nil, count: ObservationLimits.displayCount)
        nextActiveSlot = 0
    }
}
