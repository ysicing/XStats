// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Foundation
import Localization
import Metrics
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
  @ObservationIgnored private let collect:
    @Sendable (Set<String>) async throws -> [SystemCheckFinding]

  init(
    timeout: Duration = .seconds(60),
    collect: @escaping @Sendable (Set<String>) async throws -> [SystemCheckFinding] =
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
    let names = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
    isChecking = true
    Log.app.notice("System check started")
    let collect = collect
    let work = Task { [weak self] in
      do {
        let results = try await collect(names)
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
            id: "failed", title: tr("系统检查"), status: .unchecked, isComplete: false,
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
          id: "timeout", title: tr("系统检查"), status: .unchecked, isComplete: false,
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
  private static func collect(_ names: Set<String>) async throws -> [SystemCheckFinding] {
    var findings = try await SystemCheck.local()
    let resources = try await SystemResourceCheck.sample()
    findings.append(
      SystemCheckFinding(
        id: "cpu", title: tr("CPU 短时检查"),
        status: !resources.cpu.isEmpty ? .attention : resources.cpuComplete ? .normal : .unchecked,
        isComplete: resources.cpuComplete,
        detail: tr("仅报告连续两个采样区间均占用至少 25% 单核 CPU 的进程；不代表长期故障。"),
        evidence: resources.cpu.map {
          "\($0.family) · \(Format.percent($0.firstCPU)) / \(Format.percent($0.secondCPU))"
        }))
    if let first = resources.firstMemory, let second = resources.memory {
      let swapOut =
        second.swapOutBytes >= first.swapOutBytes
        ? second.swapOutBytes - first.swapOutBytes : 0
      findings.append(
        SystemCheckFinding(
          id: "memory", title: tr("内存压力"),
          status: SystemResourceCheck.memoryNeedsAttention(first: first, second: second)
            ? .attention : .normal,
          detail: tr("累计交换空间占用不单独视为异常。"),
          evidence: [
            tr("采样期间换出 \(Format.bytes(swapOut))"),
            tr("交换空间占用 \(Format.bytes(second.swapUsed))"),
          ] + resources.topMemory.map { "\($0.name) · \(Format.bytes($0.memory))" }))
    } else {
      findings.append(
        SystemCheckFinding(
          id: "memory", title: tr("内存压力"), status: .unchecked, isComplete: false,
          detail: tr("无法完成检查，请稍后重试。")))
    }
    try Task.checkCancellation()
    let details = NetworkDetailsReader.read()
    let proxy = ProxyEnvironmentReader.read(details: details, runningAppNames: Array(names))
    findings.append(
      SystemCheckFinding(
        id: "dns", title: tr("DNS 维护"), status: .optional,
        detail: proxy.hasProxy || proxy.usesFakeIPDNS
          ? tr("检测到代理或隧道环境；DNS 维护可能影响现有连接，请先排查代理设置。")
          : tr("刷新 DNS 仅是可选维护；当前检查不执行刷新，也不据此判断网络故障。")))
    findings.append(
      try await SystemCheck.homebrew(
        environment: CleanEnvironment(runningBundleIdentifiers: { [] })))
    return findings
  }
}
