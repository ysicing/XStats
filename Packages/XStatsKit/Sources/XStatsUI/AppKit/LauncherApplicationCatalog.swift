// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OSLog

struct LauncherApplicationSnapshot: Sendable {
  let commands: [AppCommand]
  let isTruncated: Bool
}

/// 两个启动入口共享短期清单；最后一个读取方取消后停止扫描，不使用后台刷新定时器。
@MainActor
final class LauncherApplicationCatalog: NSObject {
  static let shared = LauncherApplicationCatalog(observesChanges: true)

  private let clock: () -> TimeInterval
  private let loader: @Sendable () async throws -> LauncherApplicationSnapshot
  private var cached: (snapshot: LauncherApplicationSnapshot, time: TimeInterval)?
  private var worker: Task<Void, Never>?
  private var generation = UUID()
  private var waiters: [UUID: CheckedContinuation<LauncherApplicationSnapshot, any Error>] = [:]

  init(
    observesChanges: Bool = false,
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    loader: @escaping @Sendable () async throws -> LauncherApplicationSnapshot = {
      let scan = Task.detached(priority: .userInitiated) {
        let result = try CommandBarApplications.scanResult()
        return LauncherApplicationSnapshot(
          commands: result.commands, isTruncated: result.isTruncated)
      }
      return try await withTaskCancellationHandler {
        try await scan.value
      } onCancel: {
        scan.cancel()
      }
    }
  ) {
    self.clock = clock
    self.loader = loader
    super.init()
    if observesChanges {
      NotificationCenter.default.addObserver(
        self, selector: #selector(invalidateFromNotification),
        name: .launcherApplicationsChanged, object: nil)
    }
  }

  func load(force: Bool = false) async throws -> LauncherApplicationSnapshot {
    try Task.checkCancellation()
    if force { invalidate() }
    if let cached, clock() - cached.time < 30 { return cached.snapshot }
    let request = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        waiters[request] = continuation
        guard worker == nil else { return }
        let current = generation
        let loader = loader
        worker = Task { [weak self] in
          let result: Result<LauncherApplicationSnapshot, any Error>
          do {
            let snapshot = try await loader()
            try Task.checkCancellation()
            result = .success(snapshot)
          } catch {
            result = .failure(error)
          }
          self?.finish(result, generation: current)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel(request) }
    }
  }

  func invalidate() {
    cached = nil
    worker?.cancel()
    worker = nil
    generation = UUID()
    let pending = waiters.values
    waiters.removeAll()
    for continuation in pending { continuation.resume(throwing: CancellationError()) }
  }

  @objc private func invalidateFromNotification() {
    invalidate()
    LauncherIconCache.shared.invalidate()
  }

  private func cancel(_ request: UUID) {
    waiters.removeValue(forKey: request)?.resume(throwing: CancellationError())
    if waiters.isEmpty {
      worker?.cancel()
      worker = nil
      generation = UUID()
    }
  }

  private func finish(
    _ result: Result<LauncherApplicationSnapshot, any Error>, generation completed: UUID
  ) {
    guard generation == completed else { return }
    worker = nil
    if case .success(let snapshot) = result {
      cached = (snapshot, clock())
    } else if case .failure(let error) = result, !(error is CancellationError) {
      Logger(subsystem: Log.subsystem, category: "Launcher").error("Application catalog failed")
    }
    let pending = waiters.values
    waiters.removeAll()
    for continuation in pending { continuation.resume(with: result) }
  }
}
