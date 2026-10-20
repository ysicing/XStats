// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Foundation
import Localization
import Observation
import os

@MainActor @Observable
final class AICleanupController {
  enum Phase { case idle, scanning, checking, cleaning }
  enum Confirmation {
    case worktree(AIWorktree)
  }
  private(set) var phase: Phase = .idle
  private(set) var scan: AICleanupScan?
  var confirmation: Confirmation?
  private(set) var message: String?
  private(set) var isError = false
  private var generation = 0
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var environment: AICleanupEnvironment
  @ObservationIgnored private let scanner:
    @Sendable (AICleanupEnvironment) async throws -> AICleanupScan
  private static let logger = Logger(subsystem: "work.12306.xstats", category: "ai-cleanup")

  init(
    environment: AICleanupEnvironment? = nil,
    scanner: @escaping @Sendable (AICleanupEnvironment) async throws -> AICleanupScan = {
      try await AIAgentCleanup.scan(environment: $0)
    }
  ) {
    self.environment = environment ?? AICleanupEnvironment()
    self.scanner = scanner
  }

  var isBusy: Bool { phase != .idle }

  func loadIfNeeded(excludedPaths: [String]) {
    if Set(environment.clean.excludedPaths) != Set(excludedPaths) {
      // 缓存中的 Worktree 保护状态依赖保留项目；配置变化时不能继续沿用。
      environment.searchRoots = scan?.searchedRoots ?? environment.searchRoots
      environment.clean.excludedPaths = excludedPaths
      invalidate()
    }
    guard scan == nil else { return }
    refresh()
  }

  func invalidate() {
    cancel()
    scan = nil
    message = nil
    isError = false
  }

  func refresh(additionalRoot: URL? = nil) {
    guard !isBusy else { return }
    cancel()
    message = nil
    var current = environment
    if let additionalRoot {
      let existing = scan?.searchedRoots ?? []
      current.searchRoots = Array(Set(existing + [additionalRoot]))
    } else if let roots = scan?.searchedRoots {
      current.searchRoots = roots
    }
    let token = generation
    phase = .scanning
    task = Task {
      do {
        let result = try await scanner(current)
        guard !Task.isCancelled, generation == token else { return }
        scan = result
      } catch {
        guard !Task.isCancelled, generation == token else { return }
        show(tr("扫描未完成，请重试"), error: true)
        Self.logger.error("AI cleanup scan failed")
      }
      guard generation == token else { return }
      phase = .idle
      task = nil
    }
  }

  func requestRemoval(_ item: AIWorktree) {
    guard !isBusy, item.canRemove else { return }
    let token = generation
    phase = .checking
    task = Task {
      do {
        try await AIWorktrees.validateRemoval(
          item, home: environment.home, excludedPaths: environment.clean.excludedPaths)
        guard !Task.isCancelled, generation == token else { return }
        confirmation = .worktree(item)
      } catch {
        guard !Task.isCancelled, generation == token else { return }
        show((error as? AIWorktree.Protection)?.title ?? tr("无法完成安全检查"), error: true)
      }
      guard generation == token else { return }
      phase = .idle
      task = nil
    }
  }

  func confirm() {
    guard !isBusy, let pending = confirmation else { return }
    confirmation = nil
    phase = .cleaning
    message = nil
    let token = generation
    task = Task {
      var notice: String
      var failed = false
      switch pending {
      case .worktree(let item):
        do {
          try await AIWorktrees.remove(
            item, home: environment.home, excludedPaths: environment.clean.excludedPaths)
          notice = tr("已移除 worktree，分支已保留")
        } catch {
          notice = (error as? AIWorktree.Protection)?.title ?? tr("移除未完成，请刷新检查实际状态")
          failed = true
        }
      }
      guard !Task.isCancelled, generation == token else { return }
      // 成功、失败均重新核对：取消或 Git 超时不代表磁盘上的操作一定未发生。
      do {
        let refreshed = try await scanner(environmentForRefresh())
        guard !Task.isCancelled, generation == token else { return }
        scan = refreshed
      } catch {
        guard !Task.isCancelled, generation == token else { return }
        failed = true
        notice = tr("操作已结束，结果待刷新确认")
        scan = nil
      }
      show(notice, error: failed)
      phase = .idle
      task = nil
    }
  }

  func cancel() {
    if phase == .cleaning {
      // Git 操作取消不代表磁盘未改变，不能在下次打开时复用操作前的结果。
      environment.searchRoots = scan?.searchedRoots ?? environment.searchRoots
      scan = nil
    }
    generation += 1
    task?.cancel()
    task = nil
    confirmation = nil
    phase = .idle
  }

  private func environmentForRefresh() -> AICleanupEnvironment {
    var current = environment
    current.searchRoots = scan?.searchedRoots ?? environment.searchRoots
    return current
  }

  private func show(_ text: String, error: Bool) {
    message = text
    isError = error
  }
}
