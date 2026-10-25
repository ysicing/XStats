// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

public struct ScanLimits: Sendable {
  public var maxEntries: Int
  public var maxDuration: TimeInterval
  public var maxCandidates: Int

  /// 配置、存储等检查的数量与时间边界；清理扫描仅使用 maxDuration 限制工具预览。
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

/// 配置、存储等检查共用发现与计量边界；清理目录仅保留取消检查。
/// 计数及终止原因只在锁内访问，锁不跨 await。
final class ScanBudget: @unchecked Sendable {
  @TaskLocal static var current: ScanBudget?

  private let limits: ScanLimits
  private let candidates: ScanCandidateBudget?
  private let enforcesCountLimits: Bool
  private let enforcesTimeLimit: Bool
  let directoryReaderExecutable: URL?
  let deadline: ContinuousClock.Instant
  private let lock = NSLock()
  private var entries = 0
  private var stopped: ScanInterruption?

  init(
    limits: ScanLimits, enforcesTimeLimit: Bool = true, enforcesCountLimits: Bool = true,
    directoryReaderExecutable: URL? = nil
  ) {
    self.limits = limits
    self.enforcesTimeLimit = enforcesTimeLimit
    self.enforcesCountLimits = enforcesCountLimits
    self.directoryReaderExecutable = directoryReaderExecutable
    // 清理扫描不保留额外的全局路径索引，避免为已取消的数量限制重复存储候选。
    candidates = enforcesCountLimits ? ScanCandidateBudget(limit: limits.maxCandidates) : nil
    let duration = limits.maxDuration.isFinite ? max(0, limits.maxDuration) : 20
    deadline = ContinuousClock.now + .seconds(duration)
  }

  var interruption: ScanInterruption? {
    if Task.isCancelled { return .cancelled }
    guard enforcesCountLimits || enforcesTimeLimit else { return nil }
    if candidates?.isExhausted == true { return .entryLimit }
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
    guard enforcesCountLimits else { return }
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
    try candidates?.visit(path)
  }
}

/// 有界检查的候选路径索引；清理扫描不使用此索引。
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
