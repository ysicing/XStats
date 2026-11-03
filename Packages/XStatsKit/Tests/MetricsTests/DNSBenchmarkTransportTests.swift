// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Metrics
import Network
import Testing

struct DNSBenchmarkTransportTests {
  @Test(arguments: [DNSBenchmarkProtocol.udp, .tcp])
  func queriesRealSocketsAndReusesStreamConnections(_ transport: DNSBenchmarkProtocol) async throws
  {
    let server = try DNSBenchmarkServerFixture(transport: transport)
    let port = try await server.start()
    defer { server.cancel() }
    let client = DNSBenchmarkClient(
      target: .init(name: "Loopback", host: "127.0.0.1", transport: transport, port: port),
      timeout: 1)
    for _ in 0..<3 {
      let sample = try await client.query("example.com")
      #expect(sample.addresses == ["192.0.2.1"])
      #expect(sample.milliseconds >= 0)
    }
    await client.close()
    #expect(server.connectionCount == 1)
  }

  @Test func cancelsPendingSocketReadsPromptly() async throws {
    let server = try DNSBenchmarkServerFixture(transport: .tcp, replies: false)
    let port = try await server.start()
    defer { server.cancel() }
    let client = DNSBenchmarkClient(
      target: .init(name: "Loopback", host: "127.0.0.1", transport: .tcp, port: port),
      timeout: 10)
    let started = ContinuousClock.now
    let task = Task { try await client.query("example.com") }
    while server.connectionCount == 0 { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await client.close()
    #expect(ContinuousClock.now - started < .seconds(2))
  }

  @Test func idleSocketTimesOut() async throws {
    let server = try DNSBenchmarkServerFixture(transport: .udp, replies: false)
    let port = try await server.start()
    defer { server.cancel() }
    let client = DNSBenchmarkClient(
      target: .init(name: "Loopback", host: "127.0.0.1", transport: .udp, port: port),
      timeout: 0.1)
    await #expect(throws: DNSBenchmarkFailure.timeout) { try await client.query("example.com") }
    await client.close()
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_DNS_LIVE_TESTS"] == "1"))
  func publicResolversUseAllFourProtocols() async throws {
    let targets = try DNSBenchmarkProtocol.allCases.map { transport in
      try #require(
        DNSBenchmarkTarget.defaults(transport: transport, systemServers: [])
          .first { $0.name == "AliDNS" })
    }
    let results = try await DNSBenchmark.run(targets: targets, rounds: 2, timeout: 5)
    #expect(Set(results.map(\.target.transport)) == Set(DNSBenchmarkProtocol.allCases))
    #expect(results.allSatisfy { $0.attempts == 2 && $0.samples.count == 2 })
    #expect(results.allSatisfy { !$0.addresses.isEmpty && ($0.firstQueryMilliseconds ?? 0) > 0 })
    let untrusted = DNSBenchmarkClient(
      target: .init(
        name: "Invalid TLS identity", host: "223.5.5.5", transport: .dot,
        tlsServerName: "invalid.example"),
      timeout: 5)
    await #expect(throws: (any Error).self) { try await untrusted.query("www.apple.com") }
    await untrusted.close()
  }
}

private final class DNSBenchmarkServerFixture: @unchecked Sendable {
  let listener: NWListener
  let transport: DNSBenchmarkProtocol
  let replies: Bool
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private let queue = DispatchQueue(label: "work.12306.xstats.tests.dns")
  var connectionCount: Int { lock.withLock { connections.count } }

  init(transport: DNSBenchmarkProtocol, replies: Bool = true) throws {
    self.transport = transport
    self.replies = replies
    listener = try NWListener(using: transport == .udp ? .udp : .tcp, on: .any)
  }

  func start() async throws -> UInt16 {
    let gate = ContinuationGate<UInt16>()
    listener.stateUpdateHandler = { [listener] state in
      if case .ready = state { gate.resume(listener.port?.rawValue ?? 0) }
      if case .failed = state { gate.resume(0) }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      lock.withLock { connections.append(connection) }
      connection.start(queue: queue)
      if replies { receive(connection, prefix: Data()) }
    }
    listener.start(queue: queue)
    let port = await withCheckedContinuation { gate.attach($0) }
    guard port > 0 else { throw DNSBenchmarkFailure.connection }
    return port
  }

  func cancel() {
    listener.cancel()
    listener.stateUpdateHandler = nil
    listener.newConnectionHandler = nil
    lock.withLock { connections.forEach { $0.cancel() } }
  }

  private func receive(_ connection: NWConnection, prefix: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
      [weak self] data, _, _, error in
      guard let self, let data, !data.isEmpty, error == nil else { return }
      let packet = prefix + data
      let query: Data
      if transport == .tcp {
        guard packet.count >= 2 else {
          receive(connection, prefix: packet)
          return
        }
        let size = Int(packet[0]) << 8 | Int(packet[1])
        guard packet.count >= size + 2 else {
          receive(connection, prefix: packet)
          return
        }
        query = Data(packet[2..<(size + 2)])
      } else {
        query = packet
      }
      guard query.count >= 12 else { return }
      var answer = Data(query)
      answer[2] = 0x81
      answer[3] = 0x80
      answer[7] = 1
      answer.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1])
      if transport == .tcp {
        answer = Data([UInt8(answer.count >> 8), UInt8(answer.count & 255)]) + answer
      }
      connection.send(
        content: answer,
        completion: .contentProcessed { [weak self] error in
          guard error == nil else { return }
          self?.receive(connection, prefix: Data())
        })
    }
  }
}
