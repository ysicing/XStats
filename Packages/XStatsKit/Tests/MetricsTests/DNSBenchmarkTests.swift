// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Metrics
import Testing

struct DNSBenchmarkTests {
  @Test func encodesAnActualDNSQuestion() throws {
    let query = try DNSBenchmarkWire.query(domain: "example.com", id: 0x1234)
    #expect(
      Array(query) == [
        0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1,
      ])
  }

  @Test func validatesCompressedAnswersAndRejectsTruncatedPackets() throws {
    let query = try DNSBenchmarkWire.query(domain: "example.com", id: 0x1234)
    let reply = Self.reply
    #expect(try DNSBenchmarkWire.addresses(in: reply, query: query) == ["93.184.216.34"])
    for count in 0..<reply.count {
      #expect(throws: (any Error).self) {
        try DNSBenchmarkWire.addresses(in: Data(reply.prefix(count)), query: query)
      }
    }
  }

  @Test func rejectsWrongIDsQuestionsResponseCodesAndCompressionLoops() throws {
    let query = try DNSBenchmarkWire.query(domain: "example.com", id: 0x1234)
    for (offset, value) in [
      (0, UInt8(0)), (2, 0x01), (2, 0x83), (3, 0x83), (4, 1), (13, 120),
      (30, 0xff),
    ] {
      var reply = Self.reply
      reply[offset] = value
      #expect(throws: (any Error).self) {
        try DNSBenchmarkWire.addresses(in: reply, query: query)
      }
    }
  }

  @Test(arguments: [
    "", "a..com", "-bad.com", "bad_.com", String(repeating: "a", count: 64) + ".com",
  ])
  func rejectsInvalidDomains(_ domain: String) {
    #expect(throws: (any Error).self) { try DNSBenchmarkWire.query(domain: domain, id: 1) }
  }

  @Test func computesPercentilesAndLossWithoutCountingFailuresAsZero() {
    let target = DNSBenchmarkTarget(name: "Fixture", host: "192.0.2.53", transport: .udp)
    var result = DNSBenchmarkResult(target: target)
    for latency in [10.0, 20, 30, 40] {
      result.record(.success(.init(milliseconds: latency, addresses: ["192.0.2.1"])))
    }
    result.record(.failure(.timeout))
    #expect(result.median == 25)
    #expect(result.p90 == 40)
    #expect(result.failureRate == 0.2)
    #expect(result.attempts == 5)
    #expect(result.addresses == ["192.0.2.1"])
  }

  @Test func customEndpointsValidateProtocolPortAndTLSIdentity() throws {
    let ipv6 = try #require(DNSBenchmarkTarget.custom("[2001:db8::53]", transport: .tcp))
    #expect(ipv6.host == "2001:db8::53")
    #expect(ipv6.port == 53)
    let tls = try #require(DNSBenchmarkTarget.custom("tls://dns.example.com:8853", transport: .dot))
    #expect(tls.tlsServerName == "dns.example.com")
    #expect(tls.port == 8853)
    #expect(DNSBenchmarkTarget.custom("https://dns.example.com/dns-query", transport: .doh) != nil)
    for value in [
      "http://dns.example.com/dns-query", "https://user:pass@dns.example.com/dns-query",
      "https://dns.example.com:0/dns-query", "https://dns.example.com/dns-query#fragment",
    ] {
      #expect(DNSBenchmarkTarget.custom(value, transport: .doh) == nil)
    }
    #expect(DNSBenchmarkTarget.custom("tls://dns.example.com", transport: .udp) == nil)
    #expect(DNSBenchmarkTarget.custom("192.0.2.1:99999", transport: .udp) == nil)
  }

  @Test func warmupsAreExcludedAndRoundsAreInterleavedWithBoundedConcurrency() async throws {
    let ledger = DNSBenchmarkLedger()
    let targets = [
      DNSBenchmarkTarget(name: "First", host: "192.0.2.2", transport: .dot),
      DNSBenchmarkTarget(name: "Second", host: "192.0.2.3", transport: .dot),
      DNSBenchmarkTarget(name: "Third", host: "192.0.2.4", transport: .dot),
    ]
    let results = try await DNSBenchmark.run(
      targets: targets, rounds: 3,
      probe: { target, domain in
        await ledger.begin(target.id)
        await Task.yield()
        await ledger.end()
        return DNSBenchmarkSample(milliseconds: 12, addresses: ["192.0.2.10"])
      })
    #expect(results.count == 3)
    #expect(results.allSatisfy { $0.attempts == 3 && $0.median == 12 })
    let calls = await ledger.calls
    #expect(calls.count == 18)
    for target in targets {
      #expect(calls.filter { $0 == target.id }.count == 6)
    }
    #expect(await ledger.maximumActive <= 6)
  }

  @Test func allProtocolsShareSixSlotsWithoutOverlappingQueriesOnOneConnection() async throws {
    let gate = DNSBenchmarkConcurrencyGate()
    let targets = (0..<6).map { index in
      DNSBenchmarkTarget(
        name: "Fixture \(index)", host: "198.51.100.\(index + 1)",
        transport: DNSBenchmarkProtocol.allCases[index % 4])
    }
    let results = try await DNSBenchmark.run(
      targets: targets, rounds: 2,
      probe: { target, _ in
        if target.host == "192.0.2.1" { throw DNSBenchmarkFailure.timeout }
        await gate.enter(target.id)
        await gate.leave(target.id)
        return DNSBenchmarkSample(milliseconds: 12)
      })
    #expect(results.count == 6)
    #expect(results.allSatisfy { $0.attempts == 2 && $0.median == 12 })
    #expect(results.allSatisfy { $0.firstQueryMilliseconds != nil })
    #expect(await gate.maximumActive == 6)
    #expect(await gate.overlapped == false)
  }

  @Test func udpAndTCPInterceptionAreCheckedIndependently() async throws {
    let targets = DNSBenchmarkProtocol.allCases.map {
      DNSBenchmarkTarget(name: "Fixture", host: "198.51.100.53", transport: $0)
    }
    let results = try await DNSBenchmark.run(
      targets: targets, rounds: 1,
      probe: { target, _ in
        if target.host == "192.0.2.1", target.transport == .tcp {
          throw DNSBenchmarkFailure.timeout
        }
        return DNSBenchmarkSample(milliseconds: 10)
      })
    #expect(results.first { $0.target.transport == .udp }?.intercepted == true)
    #expect(results.filter { $0.target.transport != .udp }.allSatisfy { !$0.intercepted })
  }

  @Test func slowEndpointsDoNotBlockOtherProtocolsFromFinishingTheirRounds() async throws {
    let gate = DNSBenchmarkSlowGate()
    let targets = (0..<6).map { index in
      DNSBenchmarkTarget(
        name: "Fixture \(index)", host: "198.51.100.\(index)",
        transport: index == 0 ? .dot : .doh)
    }
    let results = try await withThrowingTaskGroup(of: [DNSBenchmarkResult].self) { group in
      group.addTask {
        try await DNSBenchmark.run(
          targets: targets, rounds: 2,
          probe: { target, _ in
            if target.host == "198.51.100.0" {
              await gate.waitForFastEndpoints()
            } else {
              await gate.fastQueryCompleted()
            }
            return DNSBenchmarkSample(milliseconds: 10)
          })
      }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        await gate.release()
        throw DNSBenchmarkFailure.timeout
      }
      defer { group.cancelAll() }
      return try await #require(group.next())
    }
    #expect(results.allSatisfy { $0.attempts == 2 })
    #expect(await gate.fastQueries == 25)
  }

  @Test func defaultsDeduplicateSystemAndPublicResolvers() {
    let targets = DNSBenchmarkTarget.defaults(
      transport: .udp, systemServers: ["1.1.1.1", "1.1.1.1"])
    #expect(targets.filter { $0.host == "1.1.1.1" }.count == 1)
    #expect(targets.first?.isSystem == true)
    let publicHTTPS = DNSBenchmarkTarget.defaults(transport: .doh, systemServers: [])
      .first { $0.name == "AliDNS" }
    let customHTTPS = DNSBenchmarkTarget.custom("https://dns.alidns.com/dns-query", transport: .doh)
    #expect(publicHTTPS?.id == customHTTPS?.id)
    for invalid in ["-bad.example", "bad..example", "bad_:853", "[not-ipv6]"] {
      #expect(DNSBenchmarkTarget.custom(invalid, transport: .dot) == nil)
    }
  }

  @Test func interceptionResponsesAreNeverRanked() async throws {
    let target = DNSBenchmarkTarget(name: "Fixture", host: "192.0.2.53", transport: .udp)
    let results = try await DNSBenchmark.run(
      targets: [target], rounds: 1,
      probe: { _, _ in
        DNSBenchmarkSample(milliseconds: 1, addresses: ["192.0.2.10"])
      })
    let result = try #require(results.first)
    #expect(result.intercepted)
    #expect(result.score == nil)
    #expect(result.median == 1)
  }

  @Test func validEmptyAndNegativeResponsesHaveNoAnswerSemantics() throws {
    let query = try DNSBenchmarkWire.query(domain: "example.com", id: 0x1234)
    for responseCode in [UInt8(0), 3, 5] {
      var response = query
      response[2] = 0x81
      response[3] = 0x80 | responseCode
      #expect(throws: DNSBenchmarkFailure.noAnswer) {
        try DNSBenchmarkWire.addresses(in: response, query: query)
      }
    }
  }

  @Test func validEmptyInterceptionResponsesAlsoExcludeRecommendations() async throws {
    let target = DNSBenchmarkTarget(name: "Fixture", host: "192.0.2.53", transport: .udp)
    let results = try await DNSBenchmark.run(
      targets: [target], rounds: 1,
      probe: { target, _ in
        if target.host == "192.0.2.1" { throw DNSBenchmarkFailure.noAnswer }
        return DNSBenchmarkSample(milliseconds: 1, addresses: ["192.0.2.10"])
      })
    #expect(results.first?.intercepted == true)
    #expect(results.first?.score == nil)
    #expect(results.first?.median == 1)
  }

  @Test func cancellationStopsSchedulingMoreQueries() async throws {
    let ledger = DNSBenchmarkLedger()
    let targets = (1...6).map {
      DNSBenchmarkTarget(name: "Fixture \($0)", host: "198.51.100.\($0)", transport: .dot)
    }
    let task = Task {
      try await DNSBenchmark.run(
        targets: targets, rounds: 20,
        probe: { target, _ in
          await ledger.begin(target.id)
          try await Task.sleep(for: .seconds(30))
          return DNSBenchmarkSample(milliseconds: 1)
        })
    }
    while await ledger.calls.count < 6 { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await ledger.calls.count == 6)
  }

  @Test func unreachableEndpointsStopAfterConsecutiveFailuresAndKeepProgressConserved() async throws
  {
    let ledger = DNSBenchmarkLedger()
    let progress = DNSBenchmarkProgressRecorder()
    let dead = DNSBenchmarkTarget(name: "Dead", host: "198.51.100.1", transport: .dot)
    let alive = DNSBenchmarkTarget(name: "Alive", host: "198.51.100.2", transport: .dot)
    let results = try await DNSBenchmark.run(
      targets: [dead, alive], rounds: 10,
      probe: { target, _ in
        await ledger.begin(target.id)
        await ledger.end()
        if target.id == dead.id { throw DNSBenchmarkFailure.timeout }
        return DNSBenchmarkSample(milliseconds: 5)
      },
      progress: { _, completed, total in progress.record(completed, total) })
    let calls = await ledger.calls
    #expect(calls.filter { $0 == dead.id }.count == DNSBenchmark.consecutiveFailureLimit)
    #expect(calls.filter { $0 == alive.id }.count == 13)
    let deadResult = try #require(results.first { $0.target.id == dead.id })
    #expect(deadResult.attempts == 10)
    #expect(deadResult.samples.isEmpty)
    #expect(deadResult.failureRate == 1)
    #expect(deadResult.lastFailure == .timeout)
    let aliveResult = try #require(results.first { $0.target.id == alive.id })
    #expect(aliveResult.attempts == 10 && aliveResult.median == 5)
    let last = try #require(progress.last)
    #expect(last.completed == 26 && last.total == 26)
    #expect(progress.isMonotonic)
  }

  @Test func intermittentFailuresBelowTheLimitDoNotSkipQueries() async throws {
    let counter = DNSBenchmarkLedger()
    let target = DNSBenchmarkTarget(name: "Flaky", host: "198.51.100.3", transport: .dot)
    let results = try await DNSBenchmark.run(
      targets: [target], rounds: 4,
      probe: { target, _ in
        await counter.begin(target.id)
        await counter.end()
        // 每三次查询失败两次，连续失败永远不到上限。
        if await counter.calls.count % 3 != 0 { throw DNSBenchmarkFailure.timeout }
        return DNSBenchmarkSample(milliseconds: 7)
      })
    #expect(await counter.calls.count == 7)
    #expect(results.first?.attempts == 4)
  }

  @Test func interceptionProbeNeverSharesAnIDWithACustomEndpointAtTheSameAddress() async throws {
    let ledger = DNSBenchmarkLedger()
    let custom = try #require(DNSBenchmarkTarget.custom("192.0.2.1", transport: .udp))
    _ = try await DNSBenchmark.run(
      targets: [custom], rounds: 1,
      probe: { target, _ in
        await ledger.begin(target.id)
        await ledger.end()
        return DNSBenchmarkSample(milliseconds: 3, addresses: ["192.0.2.10"])
      })
    let ids = Set(await ledger.calls)
    #expect(ids.count == 2)
    #expect(ids.contains(custom.id))
  }

  static let reply = Data([
    0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0,
    7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1,
    0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34,
  ])
}

private final class DNSBenchmarkProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [(completed: Int, total: Int)] = []
  func record(_ completed: Int, _ total: Int) {
    lock.lock()
    values.append((completed, total))
    lock.unlock()
  }
  var last: (completed: Int, total: Int)? {
    lock.lock()
    defer { lock.unlock() }
    return values.last
  }
  var isMonotonic: Bool {
    lock.lock()
    defer { lock.unlock() }
    return zip(values, values.dropFirst()).allSatisfy { $0.completed <= $1.completed }
  }
}

private actor DNSBenchmarkLedger {
  var calls: [String] = []
  var active = 0
  var maximumActive = 0
  func begin(_ target: String) {
    calls.append(target)
    active += 1
    maximumActive = max(maximumActive, active)
  }
  func end() { active -= 1 }
}

private actor DNSBenchmarkConcurrencyGate {
  private var active: Set<String> = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var opened = false
  var maximumActive = 0
  var overlapped = false

  func enter(_ target: String) async {
    if !active.insert(target).inserted { overlapped = true }
    maximumActive = max(maximumActive, active.count)
    if active.count == 6 {
      opened = true
      for waiter in waiters { waiter.resume() }
      waiters = []
    }
    if !opened { await withCheckedContinuation { waiters.append($0) } }
  }

  func leave(_ target: String) { active.remove(target) }
}

private actor DNSBenchmarkSlowGate {
  var fastQueries = 0
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?

  func waitForFastEndpoints() async {
    if released { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func fastQueryCompleted() {
    fastQueries += 1
    if fastQueries == 25 { release() }
  }

  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}
