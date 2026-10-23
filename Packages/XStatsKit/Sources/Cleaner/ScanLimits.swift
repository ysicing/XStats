// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

public struct ScanLimits: Sendable {
  public var maxEntries: Int
  public var maxDuration: TimeInterval
  public var maxCandidates: Int

  /// 同一次扫描共用总上限，条目额度按规则分配；候选数另设上限，限制排序与路径索引的内存。
  public init(
    maxEntries: Int = 100_000, maxDuration: TimeInterval = 20, maxCandidates: Int = 10_000
  ) {
    self.maxEntries = max(0, maxEntries)
    self.maxDuration = maxDuration.isFinite ? max(0, maxDuration) : 20
    self.maxCandidates = max(0, maxCandidates)
  }
}

public enum ScanInterruption: Error, Sendable, Equatable {
  case entryLimit, timeLimit, cancelled

  public var title: String {
    switch self {
    case .entryLimit: tr("已达到扫描条目上限")
    case .timeLimit: tr("已达到扫描时间上限")
    case .cancelled: tr("扫描已取消")
    }
  }
}

/// 同步目录发现与异步规则共享预算。计数及终止原因只在锁内访问，锁不跨 await。
final class ScanBudget: @unchecked Sendable {
  @TaskLocal static var current: ScanBudget?

  private let limits: ScanLimits
  private let shared: ScanBudget?
  let deadline: ContinuousClock.Instant
  private let lock = NSLock()
  private var entries = 0
  private var candidates = 0
  private var candidatePaths = Set<String>()
  private var stopped: ScanInterruption?

  init(limits: ScanLimits, sharing shared: ScanBudget? = nil) {
    self.limits = limits
    self.shared = shared
    let duration = limits.maxDuration.isFinite ? max(0, limits.maxDuration) : 20
    let deadline = ContinuousClock.now + .seconds(duration)
    self.deadline = min(deadline, shared?.deadline ?? deadline)
  }

  var remainingEntries: Int {
    lock.withLock { limits.maxEntries - entries }
  }

  var interruption: ScanInterruption? {
    if Task.isCancelled { return .cancelled }
    if let interruption = shared?.interruption { return interruption }
    return lock.withLock {
      if stopped == nil, ContinuousClock.now >= deadline { stopped = .timeLimit }
      return stopped
    }
  }

  func check() throws {
    if let interruption { throw interruption }
  }

  func visit() throws {
    try check()
    try lock.withLock {
      if let stopped { throw stopped }
      guard entries < limits.maxEntries else {
        stopped = .entryLimit
        throw ScanInterruption.entryLimit
      }
      entries += 1
    }
  }

  func visitCandidate(_ path: String) throws {
    try check()
    if let shared {
      try shared.visitCandidate(path)
      return
    }
    try lock.withLock {
      if let stopped { throw stopped }
      guard candidatePaths.insert(path).inserted else { return }
      guard candidates < limits.maxCandidates else {
        stopped = .entryLimit
        throw ScanInterruption.entryLimit
      }
      candidates += 1
    }
  }
}
