//
//  FanControl.swift
//  XStats
//
//  风扇读写。Apple Silicon 解锁流程参考 exelban/stats (MIT)：
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

// Copyright (c) 2026 GiantAccel, LLC (OpenStats fan-control behavior)
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.
import Foundation
import os

public struct FanState: Sendable, Equatable, Identifiable {
  public let id: Int
  public var current: Double
  public var minimum: Double
  public var maximum: Double
  public var target: Double
  public var isManual: Bool
  /// 固件报告起步、且尚未读到转速；展示窗口有上限，不掩盖持续停转。
  public var isStarting: Bool
  /// 模式键是否读到。读不到时 isManual 只是占位的 false，不能据此认定风扇已交还系统。
  public var isModeKnown: Bool

  public init(
    id: Int, current: Double, minimum: Double, maximum: Double, target: Double, isManual: Bool,
    isStarting: Bool = false, isModeKnown: Bool = true
  ) {
    self.id = id
    self.current = current
    self.minimum = minimum
    self.maximum = maximum
    self.target = target
    self.isManual = isManual
    self.isStarting = isStarting
    self.isModeKnown = isModeKnown
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
  /// 曾读到状态键的风扇；之后读不到视为偶发失败，沿用原窗口而不是改用手动目标推断。
  private var reportsStatus: Set<Int> = []

  /// target、isManual 为 nil 表示该键读取失败。
  mutating func update(
    id: Int, current: Double, target: Double?, isManual: Bool?,
    status: Double?, now: TimeInterval
  ) -> Bool {
    if status != nil { reportsStatus.insert(id) }
    // 缺少判断依据时视为偶发失败，沿用原窗口，避免恢复读数后重新开始提示。
    let unknown = status == nil && (reportsStatus.contains(id) || target == nil || isManual == nil)
    if current == 0, unknown {
      return startedAt[id].map { now - $0 < 10 } ?? false
    }
    let manualTarget = isManual == true && target.map { $0.isFinite && $0 > 0 } == true
    let starting = status.map { $0 == 1 } ?? manualTarget
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
    reportsStatus = reportsStatus.filter { (0..<fanCount).contains($0) }
  }
}

/// 与真实 SMC 和确定性固件夹具共用的窄接口，不改变串行读写要求。
protocol FanSMCAccess {
  func double(_ key: SMCKey) -> Double?
  func exists(_ key: SMCKey) -> Bool
  func write(_ key: SMCKey, value: Double) throws
}

extension SMCConnection: FanSMCAccess {}

public final class FanControl {
  private static let log = Logger(subsystem: "work.12306.xstats.helper", category: "fan-control")
  private let smc: any FanSMCAccess
  private let sleep: (TimeInterval) -> Void
  private var lowercaseModeKey: Bool?
  private var startup = FanStartupTracker()

  public init(smc: SMCConnection) {
    self.smc = smc
    sleep = Thread.sleep(forTimeInterval:)
  }

  init(access: any FanSMCAccess, sleep: @escaping (TimeInterval) -> Void) {
    smc = access
    self.sleep = sleep
  }

  public var fanCount: Int {
    Int(smc.double(SMCKey("FNum")) ?? 0)
  }

  /// nil 表示 FNum 读取失败，0 才表示确认无风扇；需要区分两者时不要使用 fanCount。
  public var detectedFanCount: Int? {
    smc.double(SMCKey("FNum")).flatMap { UInt8(exactly: $0) }.map(Int.init)
  }

  public func read() -> [FanState] {
    let now = ProcessInfo.processInfo.systemUptime
    let count = detectedFanCount
    startup.retain(fanCount: count)
    guard let count else { return [] }
    let fans = (0..<count).compactMap { id -> FanState? in
      guard let current = smc.double(SMCKey("F\(id)Ac")) else { return nil }
      let minimum = smc.double(SMCKey("F\(id)Mn")) ?? 0
      let maximum = smc.double(SMCKey("F\(id)Mx")) ?? 0
      let targetReading = smc.double(SMCKey("F\(id)Tg"))
      let target = targetReading ?? current
      let modeReading = smc.double(modeKey(id))
      let mode = modeReading ?? 0
      // 仅在读数为零时多读一个状态键，运行中的风扇沿用原采样开销。
      let status = current == 0 ? smc.double(SMCKey("F\(id)St")) : nil
      let isStarting = startup.update(
        id: id, current: current, target: targetReading,
        isManual: modeReading.map { $0 == 1 }, status: status, now: now)
      return FanState(
        id: id, current: current, minimum: minimum, maximum: maximum,
        target: target, isManual: mode == 1, isStarting: isStarting,
        isModeKnown: modeReading != nil)
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
      let alreadyManual = smc.double(modeKey(id)) == 1
      do {
        if !alreadyManual { try unlockManualMode(fan: id) }
        try writeWithRetry(SMCKey("F\(id)Tg"), value: clamped)
      } catch {
        // 仅撤回本次新接管的风扇；另一个风扇仍手动时保留全局解锁。
        if !alreadyManual {
          do {
            try writeWithRetry(modeKey(id), value: 0)
            let allAutomatic =
              detectedFanCount.map { count in
                count > 0 && (0..<count).allSatisfy { smc.double(modeKey($0)) == 0 }
              } ?? false
            let ftst = SMCKey("Ftst")
            if allAutomatic, smc.exists(ftst), smc.double(ftst) == 1 {
              try writeWithRetry(ftst, value: 0)
            }
          } catch {
            Self.log.error(
              "Manual fan change rollback failed: \(String(describing: error), privacy: .private)")
          }
        }
        throw error
      }
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
    // FNum 读不到时不能当作没有风扇：helper 只在复位不抛错时才清除已接管记录，
    // 静默成功会让风扇停在手动转速，且之后不再重试。
    guard let count = detectedFanCount else {
      throw SMCError.callFailed(SMCKey("FNum"), KERN_FAILURE)
    }
    var firstError: Error?
    for id in 0..<count {
      do { try setAutomatic(fan: id) } catch { firstError = firstError ?? error }
    }
    #if arch(arm64)
      // 使用 Ftst 解锁的机型还需复位该键，让 thermalmonitord 接管。
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
      let key = modeKey(id)
      var lastError: Error = SMCError.writeNotApplied(key)
      // 首次直接写入成功时不触碰 Ftst、也不等待；失败后最多再尝试约 15 秒。
      for attempt in 0...300 {
        do {
          try smc.write(key, value: 1)
          guard let mode = smc.double(key) else { throw SMCError.readbackFailed(key) }
          if mode == 1 { return }
          lastError = SMCError.writeNotApplied(key)
        } catch {
          lastError = error
        }
        if attempt == 0 {
          // Ftst 是可选解锁步骤；部分 M1 也没有该键，仍需重试模式写入并读回确认。
          let ftst = SMCKey("Ftst")
          if smc.exists(ftst), smc.double(ftst) != 1 {
            try writeWithRetry(ftst, value: 1, attempts: 100)
          }
        } else if attempt < 300 {
          sleep(0.05)
        }
      }
      throw lastError
    }

    private func writeWithRetry(
      _ key: SMCKey, value: Double, attempts: Int = 10, delay: TimeInterval = 0.05
    ) throws {
      var lastError: Error?
      for attempt in 0..<attempts {
        do {
          try smc.write(key, value: value)
          return
        } catch {
          lastError = error
          if attempt < attempts - 1 { sleep(delay) }
        }
      }
      throw lastError ?? SMCError.firmwareRejected(key, 0)
    }
  #endif
}
