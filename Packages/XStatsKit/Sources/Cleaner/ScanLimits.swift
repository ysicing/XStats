// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

public struct ScanLimits: Sendable {
  public var maxEntries: Int
  public var maxDuration: TimeInterval
  public var maxCandidates: Int

  /// 清理扫描共用条目与候选总上限，条目额度按规则分配；maxDuration 仅限制工具预览。
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

/// 同一规则的目录发现与计量共用条目额度，规则之间仅共享候选额度。
/// 清理目录不设时限，其他检查默认保留截止时间。
/// 计数及终止原因只在锁内访问，锁不跨 await。
final class ScanBudget: @unchecked Sendable {
  @TaskLocal static var current: ScanBudget?

  private let limits: ScanLimits
  private let candidates: ScanCandidateBudget
  private let enforcesTimeLimit: Bool
  let deadline: ContinuousClock.Instant
  private let lock = NSLock()
  private var entries = 0
  private var stopped: ScanInterruption?

  init(
    limits: ScanLimits, sharingCandidatesWith shared: ScanBudget? = nil,
    enforcesTimeLimit: Bool = true
  ) {
    self.limits = limits
    self.enforcesTimeLimit = enforcesTimeLimit
    candidates = shared?.candidates ?? ScanCandidateBudget(limit: limits.maxCandidates)
    let duration = limits.maxDuration.isFinite ? max(0, limits.maxDuration) : 20
    deadline = ContinuousClock.now + .seconds(duration)
  }

  var remainingEntries: Int {
    lock.withLock { limits.maxEntries - entries }
  }

  var interruption: ScanInterruption? {
    if Task.isCancelled { return .cancelled }
    if candidates.isExhausted { return .entryLimit }
    return lock.withLock {
      if stopped == nil, enforcesTimeLimit, ContinuousClock.now >= deadline { stopped = .timeLimit }
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
    try candidates.visit(path)
  }
}

/// 候选路径索引仍受整次扫描的总额度约束，不继承其他规则的超时或条目耗尽状态。
private final class ScanCandidateBudget: @unchecked Sendable {
  private let limit: Int
  private let lock = NSLock()
  private var paths = Set<String>()
  private var exhausted = false

  init(limit: Int) { self.limit = limit }

  var isExhausted: Bool { lock.withLock { exhausted } }

  func visit(_ path: String) throws {
    try lock.withLock {
      guard !exhausted else { throw ScanInterruption.entryLimit }
      guard !paths.contains(path) else { return }
      guard paths.count < limit else {
        exhausted = true
        throw ScanInterruption.entryLimit
      }
      paths.insert(path)
    }
  }
}
