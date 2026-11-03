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

  var rankingTransport: DNSBenchmarkProtocol = .doh
  var rounds = 10
  var customInput = ""
  private(set) var customTargets: [DNSBenchmarkTarget] = []
  private(set) var customError = false
  private(set) var phase: Phase = .idle
  private(set) var results: [DNSBenchmarkResult] = []
  private(set) var completedQueries = 0
  private(set) var totalQueries = 0
  private(set) var completedAt: Date?
  private(set) var environment: ProxyEnvironment?
  @ObservationIgnored private(set) var task: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private let environmentReader: @MainActor () async -> ProxyEnvironment
  @ObservationIgnored private let run: Runner
  private static let logger = Logger(subsystem: Log.subsystem, category: "DNSBenchmark")

  var providers: [Provider] {
    Dictionary(grouping: results, by: \.target.providerID).compactMap { id, results in
      guard let first = results.first else { return nil }
      return Provider(id: id, name: first.target.name, results: results)
    }.sorted { $0.id < $1.id }
  }

  var recommendation: DNSBenchmarkResult? {
    guard phase == .complete else { return nil }
    return bestResult(results.filter { $0.target.transport == rankingTransport })
  }

  var plainRecommendation: DNSBenchmarkResult? {
    guard phase == .complete else { return nil }
    return bestResult(results.filter { $0.target.transport == .udp || $0.target.transport == .tcp })
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
    let transport: DNSBenchmarkProtocol
    switch URLComponents(string: customInput.trimmingCharacters(in: .whitespacesAndNewlines))?
      .scheme
    {
    case "https": transport = .doh
    case "tls": transport = .dot
    case "tcp": transport = .tcp
    default: transport = .udp
    }
    guard let target = DNSBenchmarkTarget.custom(customInput, transport: transport) else {
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
    phase = .running
    results = []
    completedQueries = 0
    totalQueries = 0
    completedAt = nil
    environment = nil
    Self.logger.notice("DNS benchmark started: UDP TCP DoT DoH, rounds \(rounds)")
    task = Task { [weak self, environmentReader, run] in
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
      self.results = targets.map { DNSBenchmarkResult(target: $0) }
      self.totalQueries = targets.count * (rounds + 3)
      do {
        let results = try await run(targets, rounds) { [weak self] results, completed, total in
          Task { @MainActor [weak self] in
            guard let self, self.generation == current, self.phase == .running,
              completed >= self.completedQueries
            else { return }
            self.results = results
            self.completedQueries = completed
            self.totalQueries = total
          }
        }
        guard self.generation == current, !Task.isCancelled else { return }
        self.results = results
        self.completedQueries = self.totalQueries
        self.completedAt = Date()
        self.phase = .complete
        self.task = nil
        Self.logger.notice("DNS benchmark completed: \(results.count) servers")
      } catch {
        guard self.generation == current else { return }
        self.phase = Task.isCancelled ? .cancelled : .failed
        self.task = nil
        Self.logger.error("DNS benchmark ended without completion")
      }
    }
  }

  func cancel() {
    guard phase == .running else { return }
    generation += 1
    task?.cancel()
    task = nil
    phase = .cancelled
    Self.logger.notice("DNS benchmark cancelled")
  }
}
