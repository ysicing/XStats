// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Localization
import Observation

@MainActor
@Observable
public final class SystemCheckController {
  public private(set) var findings: [SystemCheckFinding] = []
  public private(set) var checkedAt: Date?
  public private(set) var isChecking = false
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private(set) var deadlineTask: Task<Void, Never>?
  @ObservationIgnored private let timeout: Duration
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var paused = false
  @ObservationIgnored private let collect: @Sendable () async throws -> [SystemCheckFinding]

  init(
    timeout: Duration = .seconds(60),
    collect: @escaping @Sendable () async throws -> [SystemCheckFinding] =
      SystemCheckController.collect
  ) {
    self.timeout = timeout
    self.collect = collect
  }

  @discardableResult
  func start() -> Task<Void, Never>? {
    guard !paused, !isChecking else { return nil }
    generation += 1
    let current = generation
    isChecking = true
    Log.app.notice("System check started")
    let collect = collect
    let work = Task { [weak self] in
      do {
        let results = try await collect()
        guard let self, !Task.isCancelled, current == generation else { return }
        findings = results
        checkedAt = Date()
        isChecking = false
        deadlineTask?.cancel()
        deadlineTask = nil
        task = nil
        Log.app.notice("System check completed findings=\(results.count)")
      } catch {
        guard let self, !Task.isCancelled, current == generation else { return }
        findings = [
          SystemCheckFinding(
            id: "failed", title: tr("Homebrew 依赖预览"), status: .unchecked, isComplete: false,
            detail: tr("无法完成检查，请稍后重试。"))
        ]
        checkedAt = Date()
        isChecking = false
        deadlineTask?.cancel()
        deadlineTask = nil
        task = nil
        Log.app.error("System check failed")
      }
    }
    task = work
    let timeout = timeout
    deadlineTask = Task { [weak self] in
      do { try await Task.sleep(for: timeout) } catch { return }
      guard let self, current == generation, isChecking else { return }
      cancel()
      findings = [
        SystemCheckFinding(
          id: "timeout", title: tr("Homebrew 依赖预览"), status: .unchecked, isComplete: false,
          detail: tr("已达到扫描时间上限"))
      ]
      checkedAt = Date()
      Log.app.notice("System check timed out")
    }
    return work
  }

  func cancel() {
    guard isChecking else { return }
    generation += 1
    task?.cancel()
    task = nil
    deadlineTask?.cancel()
    deadlineTask = nil
    isChecking = false
    Log.app.notice("System check cancelled")
  }

  func setPaused(_ value: Bool) {
    paused = value
    if value { cancel() }
  }

  @concurrent
  private static func collect() async throws -> [SystemCheckFinding] {
    [
      try await SystemCheck.homebrew(
        environment: CleanEnvironment(runningBundleIdentifiers: { [] }))
    ]
  }
}
