// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

/// 同一应用及其辅助进程在采样区间内的 CPU 平均功率，不包含 GPU、屏幕或整机其他耗电。
public struct AppEnergyUsage: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    public var watts: Double
}

public struct AppEnergyReading: Sendable, Equatable {
    /// 按 CPU 能耗排序的前五项；总值包括所有成功读取的进程，不等于整机功耗。
    public let apps: [AppEnergyUsage]
    public let totalWatts: Double
    /// nil 表示正在建立区间基线。
    public let interval: TimeInterval?
    public let isAvailable: Bool
}

/// 仅电池能耗分区可见时使用；直接读取内核计数，不启动 ps 或需要特权的 powermetrics。
public struct AppEnergySampler {
    struct Identity: Hashable {
        let pid: Int32
        let startTime: UInt64
    }

    struct Counter {
        let identity: Identity
        let nanojoules: UInt64
        let name: String
        let bundlePath: String?
    }

    private var previous: [Identity: UInt64] = [:]
    private var previousTime: TimeInterval?
    private var metadata: [Identity: ProcessSampler.Meta] = [:]

    public init() {}

    public mutating func sample() -> AppEnergyReading {
        let capacity = max(64, Int(proc_listallpids(nil, 0)) + 64)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = max(0, min(capacity, Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))))
        var counters: [Counter] = []
        var liveMetadata: [Identity: ProcessSampler.Meta] = [:]
        for pid in pids.prefix(count) where pid > 0 {
            var info = rusage_info_v6()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard status == 0 else { continue }
            let identity = Identity(pid: pid, startTime: info.ri_proc_start_abstime)
            // 首次基线及没有能耗增量的进程不会进入排行，无需查询路径或构造应用元数据。
            let hasEnergyDelta = previous[identity].map { info.ri_energy_nj > $0 } ?? false
            let meta = metadata[identity] ?? (hasEnergyDelta ? ProcessSampler.meta(for: pid) : nil)
            if let meta { liveMetadata[identity] = meta }
            counters.append(Counter(identity: identity, nanojoules: info.ri_energy_nj,
                                    name: meta?.name ?? "PID \(pid)", bundlePath: meta?.bundle))
        }
        // 缓存仅保留本轮仍存在且可读取的进程；PID 重用由启动时间隔离。
        metadata = liveMetadata
        return reading(counters: counters, now: ProcessInfo.processInfo.systemUptime)
    }

    /// 用累计纳焦耳差值除以实际单调时钟区间；首次读取、计数回退或 PID 重用不产生功率。
    mutating func reading(counters: [Counter], now: TimeInterval) -> AppEnergyReading {
        let interval = previousTime.flatMap { now > $0 ? now - $0 : nil }
        var groups: [String: AppEnergyUsage] = [:]
        var total: Double = 0
        for counter in counters {
            guard let interval, let before = previous[counter.identity], counter.nanojoules >= before else { continue }
            let watts = Double(counter.nanojoules - before) / 1_000_000_000 / interval
            total += watts
            guard watts > 0 else { continue }
            let key = counter.bundlePath ?? "pid-\(counter.identity.pid)-\(counter.identity.startTime)"
            if groups[key] != nil {
                groups[key]?.watts += watts
            } else {
                groups[key] = AppEnergyUsage(id: key, name: counter.name, bundlePath: counter.bundlePath, watts: watts)
            }
        }
        previous = Dictionary(uniqueKeysWithValues: counters.map { ($0.identity, $0.nanojoules) })
        previousTime = now
        let apps = groups.values.sorted { $0.watts == $1.watts ? $0.id < $1.id : $0.watts > $1.watts }
        return AppEnergyReading(apps: Array(apps.prefix(5)), totalWatts: total, interval: interval,
                                isAvailable: counters.contains { $0.nanojoules > 0 })
    }
}
