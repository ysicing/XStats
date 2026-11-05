// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Metrics
import Observation
import OSLog

@MainActor
@Observable
final class DNSBenchmarkController {
  enum Phase { case idle, running, complete, failed, cancelled }
  typealias Runner =
    @Sendable (
      [DNSBenchmarkTarget], Int, @escaping DNSBenchmark.Progress
    ) async throws -> [DNSBenchmarkResult]

  struct Provider: Identifiable {
    let id: String
    let name: String
    let results: [DNSBenchmarkResult]
    var isSystem: Bool { results.contains { $0.target.isSystem } }
    func result(for transport: DNSBenchmarkProtocol) -> DNSBenchmarkResult? {
      results.first { $0.target.transport == transport }
    }
  }

  var rankingTransport: DNSBenchmarkProtocol = .doh {
    didSet { if rankingTransport != oldValue { refreshRecommendations() } }
  }
  var rounds = 10
  var customInput = ""
  private(set) var customTargets: [DNSBenchmarkTarget] = []
  private(set) var customError = false
  private(set) var phase: Phase = .idle
  private(set) var results: [DNSBenchmarkResult] = []
  // 以下派生值只在 results/phase/rankingTransport 变化时重算一次，避免视图每次 body 求值都分组、排序。
  private(set) var providers: [Provider] = []
  private(set) var recommendation: DNSBenchmarkResult?
  private(set) var plainRecommendation: DNSBenchmarkResult?
  private(set) var completedQueries = 0
  private(set) var totalQueries = 0
  private(set) var completedAt: Date?
  private(set) var environment: ProxyEnvironment?
  @ObservationIgnored private(set) var task: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  /// 已取消但可能仍在关闭连接的旧任务；新一轮启动前等待它结束，避免新旧连接并存。
  @ObservationIgnored private var retiringTask: Task<Void, Never>?
  @ObservationIgnored private let environmentReader: @MainActor () async -> ProxyEnvironment
  @ObservationIgnored private let run: Runner
  private static let logger = Logger(subsystem: Log.subsystem, category: "DNSBenchmark")

  private func updateResults(_ newResults: [DNSBenchmarkResult]) {
    results = newResults
    providers = Dictionary(grouping: newResults, by: \.target.providerID).compactMap {
      id, results in
      guard let first = results.first else { return nil }
      return Provider(id: id, name: first.target.name, results: results)
    }.sorted { $0.id < $1.id }
    refreshRecommendations()
  }

  private func updatePhase(_ newPhase: Phase) {
    phase = newPhase
    refreshRecommendations()
  }

  private func refreshRecommendations() {
    guard phase == .complete else {
      recommendation = nil
      plainRecommendation = nil
      return
    }
    recommendation = bestResult(results.filter { $0.target.transport == rankingTransport })
    plainRecommendation = bestResult(
      results.filter { $0.target.transport == .udp || $0.target.transport == .tcp })
  }

  private func bestResult(_ results: [DNSBenchmarkResult]) -> DNSBenchmarkResult? {
    results.filter { $0.score != nil }.min {
      if $0.score == $1.score { return $0.id < $1.id }
      return ($0.score ?? .infinity) < ($1.score ?? .infinity)
    }
  }

  init(
    environmentReader: @escaping @MainActor () async -> ProxyEnvironment = {
      let apps = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
      return await Task.detached(priority: .utility) {
        ProxyEnvironmentReader.read(details: NetworkDetailsReader.read(), runningAppNames: apps)
      }.value
    },
    run: @escaping Runner = {
      try await DNSBenchmark.run(targets: $0, rounds: $1, progress: $2)
    }
  ) {
    self.environmentReader = environmentReader
    self.run = run
  }

  func addCustomTarget() {
    guard phase != .running else { return }
    let input = customInput.trimmingCharacters(in: .whitespacesAndNewlines)
    let target: DNSBenchmarkTarget?
    if let separator = input.range(of: "://") {
      // 仅识别已知协议前缀，其余交给 custom 以格式错误处理。
      let transport: DNSBenchmarkProtocol?
      switch String(input[..<separator.lowerBound]) {
      case "https": transport = .doh
      case "tls": transport = .dot
      case "tcp": transport = .tcp
      case "udp": transport = .udp
      default: transport = nil
      }
      target = transport.flatMap { DNSBenchmarkTarget.custom(input, transport: $0) }
    } else {
      // 无前缀只接受 IP 地址；加密协议须由用户显式选择。
      target = DNSBenchmarkTarget.custom(input, transport: .udp)
    }
    guard let target else {
      customError = true
      return
    }
    if !customTargets.contains(where: { $0.id == target.id }) {
      guard customTargets.count < 8 else {
        customError = true
        return
      }
      customTargets.append(target)
    }
    customInput = ""
    customError = false
  }

  func removeCustomTarget(_ target: DNSBenchmarkTarget) {
    guard phase != .running else { return }
    customTargets.removeAll { $0.id == target.id }
    customError = false
  }

  func start() {
    guard phase != .running else { return }
    generation += 1
    let current = generation
    let rounds = rounds
    let custom = customTargets
    let previous = retiringTask
    retiringTask = nil
    updatePhase(.running)
    updateResults([])
    completedQueries = 0
    totalQueries = 0
    completedAt = nil
    environment = nil
    Self.logger.notice("DNS benchmark started: UDP TCP DoT DoH, rounds \(rounds)")
    task = Task { [weak self, environmentReader, run] in
      await previous?.value
      let environment = await environmentReader()
      guard let self, self.generation == current, !Task.isCancelled else { return }
      self.environment = environment
      var targets = DNSBenchmarkProtocol.allCases.flatMap {
        DNSBenchmarkTarget.defaults(transport: $0, systemServers: environment.dnsServers)
      }
      for target in custom where !targets.contains(where: { $0.id == target.id }) {
        targets.append(target)
        if target.transport == .udp {
          let tcp = DNSBenchmarkTarget(
            name: target.name, host: target.host, transport: .tcp, port: target.port,
            providerID: target.providerID)
          if !targets.contains(where: { $0.id == tcp.id }) { targets.append(tcp) }
        }
      }
      self.updateResults(targets.map { DNSBenchmarkResult(target: $0) })
      self.totalQueries = targets.count * (rounds + 3)
      do {
        let results = try await run(targets, rounds) { [weak self] results, completed, total in
          Task { @MainActor [weak self] in
            guard let self, self.generation == current, self.phase == .running,
              completed >= self.completedQueries
            else { return }
            self.updateResults(results)
            self.completedQueries = completed
            self.totalQueries = total
          }
        }
        guard self.generation == current, !Task.isCancelled else { return }
        self.updateResults(results)
        self.completedQueries = self.totalQueries
        self.completedAt = Date()
        self.updatePhase(.complete)
        self.task = nil
        Self.logger.notice("DNS benchmark completed: \(results.count) servers")
      } catch {
        guard self.generation == current else { return }
        self.updatePhase(Task.isCancelled ? .cancelled : .failed)
        self.task = nil
        Self.logger.error("DNS benchmark ended without completion")
      }
    }
  }

  func cancel() {
    guard phase == .running else { return }
    generation += 1
    task?.cancel()
    retiringTask = task
    task = nil
    updatePhase(.cancelled)
    Self.logger.notice("DNS benchmark cancelled")
  }
}
