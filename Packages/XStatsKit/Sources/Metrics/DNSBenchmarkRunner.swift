// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum DNSBenchmark {
  public typealias Progress = @Sendable ([DNSBenchmarkResult], Int, Int) -> Void
  typealias Probe = @Sendable (DNSBenchmarkTarget, String) async throws -> DNSBenchmarkSample
  static let domains = ["www.apple.com", "www.baidu.com", "www.cloudflare.com"]
  static let maximumConcurrentQueries = 6
  /// 连续失败达到该次数即判定端点不可达，跳过其剩余查询，避免每个查询都等满超时。
  static let consecutiveFailureLimit = 3
  /// 进度发布间隔；窗口按此频率整体刷新，过密会让视图反复重算。
  static let progressInterval: Duration = .milliseconds(300)

  private struct CompletedQuery: Sendable {
    let index: Int
    let round: Int
    let outcome: Result<DNSBenchmarkSample, DNSBenchmarkFailure>
    let elapsed: Double
  }

  public static func run(
    targets: [DNSBenchmarkTarget], rounds: Int = 10, timeout: TimeInterval = 2,
    progress: @escaping Progress = { _, _, _ in }
  ) async throws -> [DNSBenchmarkResult] {
    guard timeout.isFinite, timeout > 0, timeout <= 30 else {
      throw DNSBenchmarkFailure.invalidResponse
    }
    try validate(targets: targets, rounds: rounds)
    var clients: [String: DNSBenchmarkClient] = [:]
    var probes = targets
    for transport in [DNSBenchmarkProtocol.udp, .tcp]
    where targets.contains(where: { $0.transport == transport }) {
      probes.append(interceptionTarget(transport))
    }
    for target in probes {
      clients[target.id] = DNSBenchmarkClient(target: target, timeout: timeout)
    }
    let pool = clients
    do {
      let results = try await run(
        targets: targets, rounds: rounds,
        probe: { target, domain in
          guard let client = pool[target.id] else { throw DNSBenchmarkFailure.connection }
          return try await client.query(domain)
        }, progress: progress)
      for client in pool.values { await client.close() }
      return results
    } catch {
      for client in pool.values { await client.close() }
      throw error
    }
  }

  static func run(
    targets: [DNSBenchmarkTarget], rounds: Int, probe: @escaping Probe,
    progress: @escaping Progress = { _, _, _ in }
  ) async throws -> [DNSBenchmarkResult] {
    try validate(targets: targets, rounds: rounds)
    try Task.checkCancellation()
    var results = targets.map { DNSBenchmarkResult(target: $0) }
    let total = targets.count * (rounds + domains.count)
    var completed = 0
    let intercepted = try await interceptedProtocols(targets: targets, probe: probe)
    for index in results.indices {
      results[index].intercepted = intercepted.contains(results[index].target.transport)
    }
    progress(results, completed, total)
    var lastPublished = ContinuousClock.now
    var pending = Array(targets.indices).shuffled()
    var next = 0
    var completedRounds = Array(repeating: 0, count: targets.count)
    var consecutiveFailures = Array(repeating: 0, count: targets.count)
    let queriesPerTarget = rounds + domains.count
    try await withThrowingTaskGroup(of: CompletedQuery.self) { group in
      for _ in 0..<min(maximumConcurrentQueries, targets.count) {
        let index = pending[next]
        group.addTask {
          try await query(index: index, round: 0, target: targets[index], probe: probe)
        }
        next += 1
      }
      for try await query in group {
        try Task.checkCancellation()
        if query.round == 0, case .success = query.outcome {
          results[query.index].recordFirstQuery(milliseconds: query.elapsed)
        }
        if query.round >= domains.count { results[query.index].record(query.outcome) }
        completed += 1
        completedRounds[query.index] += 1
        if case .success = query.outcome {
          consecutiveFailures[query.index] = 0
        } else {
          consecutiveFailures[query.index] += 1
        }
        if consecutiveFailures[query.index] >= consecutiveFailureLimit,
          completedRounds[query.index] < queriesPerTarget
        {
          // 不可达端点：剩余查询直接记为超时，计入进度以保持 completed 与 total 守恒，结果结构不变。
          for round in completedRounds[query.index]..<queriesPerTarget {
            completed += 1
            if round >= domains.count { results[query.index].record(.failure(.timeout)) }
          }
          completedRounds[query.index] = queriesPerTarget
        }
        if completed == total || ContinuousClock.now - lastPublished >= progressInterval {
          progress(results, completed, total)
          lastPublished = ContinuousClock.now
        }
        // 每个端点仅有一个在途请求；完成后排到队尾，慢端点不会阻塞其他协议的下一轮。
        if completedRounds[query.index] < queriesPerTarget { pending.append(query.index) }
        if next < pending.count {
          let index = pending[next]
          let round = completedRounds[index]
          group.addTask {
            try await self.query(index: index, round: round, target: targets[index], probe: probe)
          }
          next += 1
        }
      }
    }
    try Task.checkCancellation()
    return results
  }

  private static func validate(targets: [DNSBenchmarkTarget], rounds: Int) throws {
    guard (1...20).contains(rounds), (1...64).contains(targets.count),
      Set(targets.map(\.id)).count == targets.count
    else { throw DNSBenchmarkFailure.invalidResponse }
  }

  private static func query(
    index: Int, round: Int, target: DNSBenchmarkTarget, probe: Probe
  ) async throws -> CompletedQuery {
    let started = ContinuousClock.now
    let outcome = try await outcome(target, domain: domains[round % domains.count], probe: probe)
    return CompletedQuery(
      index: index, round: round, outcome: outcome,
      elapsed: SpeedConnection.milliseconds(ContinuousClock.now - started))
  }

  private static func interceptedProtocols(
    targets: [DNSBenchmarkTarget], probe: @escaping Probe
  ) async throws -> Set<DNSBenchmarkProtocol> {
    try await withThrowingTaskGroup(of: DNSBenchmarkProtocol?.self) { group in
      for transport in [DNSBenchmarkProtocol.udp, .tcp]
      where targets.contains(where: { $0.transport == transport }) {
        group.addTask {
          // 文档地址不应提供公共 DNS；UDP 与 TCP 分别判断，不能跨协议推断拦截。
          do {
            _ = try await probe(interceptionTarget(transport), domains[0])
            return transport
          } catch DNSBenchmarkFailure.noAnswer {
            return transport
          } catch {
            try Task.checkCancellation()
            return nil
          }
        }
      }
      var intercepted: Set<DNSBenchmarkProtocol> = []
      for try await transport in group {
        if let transport { intercepted.insert(transport) }
      }
      try Task.checkCancellation()
      return intercepted
    }
  }

  private static func outcome(
    _ target: DNSBenchmarkTarget, domain: String, probe: Probe
  ) async throws -> Result<DNSBenchmarkSample, DNSBenchmarkFailure> {
    try Task.checkCancellation()
    do {
      let sample = try await probe(target, domain)
      try Task.checkCancellation()
      return .success(sample)
    } catch {
      try Task.checkCancellation()
      return .failure(error as? DNSBenchmarkFailure ?? .connection)
    }
  }

  private static func interceptionTarget(_ transport: DNSBenchmarkProtocol) -> DNSBenchmarkTarget {
    // 独立的 TLS 名称让探针 id 与用户填写的同址端点（如 192.0.2.1）不冲突；UDP/TCP 不使用该字段。
    DNSBenchmarkTarget(
      name: "Interception", host: "192.0.2.1", transport: transport,
      tlsServerName: "interception.probe.invalid")
  }
}
