//
//  FanControl.swift
//  XStats
//
//  风扇读写。Apple Silicon 解锁流程参考 exelban/stats (MIT)：
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

public struct FanState: Sendable, Equatable, Identifiable {
    public let id: Int
    public var current: Double
    public var minimum: Double
    public var maximum: Double
    public var target: Double
    public var isManual: Bool
    /// 固件报告起步、且尚未读到转速；展示窗口有上限，不掩盖持续停转。
    public var isStarting: Bool

    public init(id: Int, current: Double, minimum: Double, maximum: Double, target: Double, isManual: Bool,
                isStarting: Bool = false) {
        self.id = id
        self.current = current
        self.minimum = minimum
        self.maximum = maximum
        self.target = target
        self.isManual = isManual
        self.isStarting = isStarting
    }

    /// 当前转速在 min...max 区间的占比
    public var fraction: Double {
        guard maximum > minimum else { return 0 }
        return min(1, max(0, (current - minimum) / (maximum - minimum)))
    }
}

extension Array where Element == FanState {
    /// 汇总值是否显示“启动中”：仅当没有任何风扇在转、且至少一个处于起步窗口
    public var isStartingUp: Bool {
        !contains { $0.current > 0 } && contains(where: \.isStarting)
    }
}

/// 部分机型没有起步状态键，只能以手动目标转速推断。两种来源均最多提示 10 秒，
/// 超时后保留真实的 0 RPM，直到风扇转动或起步条件消失才允许开始新的窗口。
struct FanStartupTracker {
    private var startedAt: [Int: TimeInterval] = [:]

    mutating func update(id: Int, current: Double, target: Double, isManual: Bool,
                         status: Double?, now: TimeInterval) -> Bool {
        let starting = status.map { $0 == 1 } ?? (isManual && target.isFinite && target > 0)
        guard current == 0, starting else {
            startedAt[id] = nil
            return false
        }
        let start = startedAt[id] ?? now
        startedAt[id] = start
        return now - start < 10
    }

    mutating func retain(fanCount: Int?) {
        // nil 是读取失败，不能当作确认无风扇，否则会重新开始已超时的提示。
        guard let fanCount else { return }
        startedAt = startedAt.filter { (0..<fanCount).contains($0.key) }
    }
}

public final class FanControl {
    private let smc: SMCConnection
    private var lowercaseModeKey: Bool?
    private var startup = FanStartupTracker()

    public init(smc: SMCConnection) {
        self.smc = smc
    }

    public var fanCount: Int {
        Int(smc.double(SMCKey("FNum")) ?? 0)
    }

    public func read() -> [FanState] {
        let now = ProcessInfo.processInfo.systemUptime
        let count = smc.double(SMCKey("FNum")).flatMap { UInt8(exactly: $0) }.map(Int.init)
        startup.retain(fanCount: count)
        guard let count else { return [] }
        let fans = (0..<count).compactMap { id -> FanState? in
            guard let current = smc.double(SMCKey("F\(id)Ac")) else { return nil }
            let minimum = smc.double(SMCKey("F\(id)Mn")) ?? 0
            let maximum = smc.double(SMCKey("F\(id)Mx")) ?? 0
            let target = smc.double(SMCKey("F\(id)Tg")) ?? current
            let mode = smc.double(modeKey(id)) ?? 0
            // 仅在读数为零时多读一个状态键，运行中的风扇沿用原采样开销。
            let status = current == 0 ? smc.double(SMCKey("F\(id)St")) : nil
            let isStarting = startup.update(id: id, current: current, target: target,
                                            isManual: mode == 1, status: status, now: now)
            return FanState(id: id, current: current, minimum: minimum, maximum: maximum,
                            target: target, isManual: mode == 1, isStarting: isStarting)
        }
        return fans
    }

    // MARK: 写入（需要 root）

    /// 设为手动并指定目标转速；转速会被限制在固件给出的 min...max 之间。
    public func setManual(fan id: Int, rpm: Double) throws {
        let minimum = smc.double(SMCKey("F\(id)Mn")) ?? 0
        let maximum = smc.double(SMCKey("F\(id)Mx")) ?? rpm
        let clamped = min(max(rpm, minimum), maximum)

        #if arch(arm64)
        if smc.double(modeKey(id)) != 1 {
            try unlockManualMode(fan: id)
        }
        try writeWithRetry(SMCKey("F\(id)Tg"), value: clamped)
        #else
        try smc.write(SMCKey("F\(id)Md"), value: 1)
        try smc.write(SMCKey("F\(id)Tg"), value: clamped)
        #endif
    }

    public func setAutomatic(fan id: Int) throws {
        #if arch(arm64)
        if smc.double(modeKey(id)) != 0 {
            try writeWithRetry(modeKey(id), value: 0)
        }
        #else
        try smc.write(SMCKey("F\(id)Md"), value: 0)
        #endif
    }

    /// 全部风扇恢复系统自动控制
    public func resetAll() throws {
        var firstError: Error?
        for id in 0..<fanCount {
            do { try setAutomatic(fan: id) } catch { firstError = firstError ?? error }
        }
        #if arch(arm64)
        // M1–M4 需要复位 Ftst，让 thermalmonitord 接管
        let ftst = SMCKey("Ftst")
        if smc.exists(ftst), smc.double(ftst) == 1 {
            do { try writeWithRetry(ftst, value: 0) } catch { firstError = firstError ?? error }
        }
        #endif
        if let firstError { throw firstError }
    }

    // MARK: 私有

    private func modeKey(_ id: Int) -> SMCKey {
        if lowercaseModeKey == nil {
            lowercaseModeKey = smc.exists(SMCKey("F0md"))
        }
        return SMCKey(lowercaseModeKey == true ? "F\(id)md" : "F\(id)Md")
    }

    #if arch(arm64)
    private func unlockManualMode(fan id: Int) throws {
        // M5 及以后：直接写模式键即可
        if (try? smc.write(modeKey(id), value: 1)) != nil { return }

        // M1–M4：先写 Ftst=1，等待 thermalmonitord 让出控制权
        let ftst = SMCKey("Ftst")
        guard smc.exists(ftst) else { throw SMCError.firmwareRejected(modeKey(id), 0) }
        if smc.double(ftst) != 1 {
            try writeWithRetry(ftst, value: 1, attempts: 100)
            Thread.sleep(forTimeInterval: 3)
        }
        try writeWithRetry(modeKey(id), value: 1, attempts: 300, delay: 0.1)
    }

    private func writeWithRetry(_ key: SMCKey, value: Double, attempts: Int = 10, delay: TimeInterval = 0.05) throws {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                try smc.write(key, value: value)
                return
            } catch {
                lastError = error
                if attempt < attempts - 1 { Thread.sleep(forTimeInterval: delay) }
            }
        }
        throw lastError ?? SMCError.firmwareRejected(key, 0)
    }
    #endif
}
