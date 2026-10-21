// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network
import Testing
@testable import Metrics

struct LocalIPQueryTests {
  @Test func keepsGeographyWithItsActualAddress() throws {
    let body = Data(
      #"{"ok":true,"ip":"203.0.113.24","geo":{"country_code":"JP","city":"Tokyo"},"network":{"asn":64500,"isp":"Example"}}"#
        .utf8)
    let result = try #require(LocalIPQuery.parse(body, source: .ipv4))
    #expect(result.ipv4 == "203.0.113.24")
    #expect(result.ipv6 == nil)
    #expect(result.countryCode == "JP")
    #expect(result.asn == "AS64500")
    #expect(result.organization == "Example")
    #expect(LocalIPQuery.parse(body, source: .ipv6) == nil)
  }

  @Test func acceptsIPv6OnlyForCorrectFamily() throws {
    let body = Data(#"{"ip":"2001:db8::1"}"#.utf8)
    let result = try #require(LocalIPQuery.parse(body, source: .ipv6))
    #expect(result.ipv6 == "2001:db8::1")
    #expect(result.ipv4 == nil)
    #expect(LocalIPQuery.parse(body, source: .ipv4) == nil)
  }

  @Test func domesticEchoDoesNotInventLocation() throws {
    let body = Data(#"{"ip":" 198.51.100.2 ","extra":123}"#.utf8)
    let result = try #require(LocalIPQuery.parse(body, source: .domestic))
    #expect(result.ipv4 == "198.51.100.2")
    #expect(result.countryCode == nil && result.asn == nil)
  }

  @Test func cloudflareUsesReturnedFamilyAndCountry() throws {
    let body = Data("ip=2001:db8::2\nloc=us\n".utf8)
    let result = try #require(LocalIPQuery.parse(body, source: .cloudflare))
    #expect(result.ipv6 == "2001:db8::2" && result.ipv4 == nil)
    #expect(result.countryCode == "US")
  }

  @Test func ipifyEchoHasItsOwnAddressWithoutBorrowedGeography() throws {
    let response = LocalIPQuery.decode(
      Data(#"{"ip":"192.0.2.42"}"#.utf8), status: 200, source: .ipify)
    let result = try response.get()
    #expect(result.ipv4 == "192.0.2.42")
    #expect(result.countryCode == nil && result.organization == nil && result.asn == nil)
  }

  @Test func distinguishesServiceTransportAndPayloadFailures() {
    #expect(LocalIPQuery.decode(nil, status: 0, source: .ipv6) == .failure(.connection))
    #expect(LocalIPQuery.decode(nil, status: 429, source: .ipv4) == .failure(.http(429)))
    #expect(LocalIPQuery.decode(Data(), status: 503, source: .ipify) == .failure(.http(503)))
    #expect(
      LocalIPQuery.decode(Data("<html>blocked</html>".utf8), status: 200, source: .cloudflare)
        == .failure(.invalidResponse))
    #expect(
      LocalIPQuery.decode(Data(#"{"ip":"192.0.2.1"}"#.utf8), status: 200, source: .ipv6)
        == .failure(.invalidResponse))
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func exchangeCompletesAndClosesWithoutWaitingForTimeout(cancelWhileWaiting: Bool) async throws {
    // 本地 TCP 夹具只接收请求、不发送响应，确定连接正在等待；不访问第三方服务。
    let queue = DispatchQueue(label: "XStats.LocalIPQueryTests")
    let listener = try NWListener(using: .tcp, on: .any)
    let (ports, ready) = AsyncStream<NWEndpoint.Port>.makeStream()
    let (peers, received) = AsyncStream<NWConnection>.makeStream()
    listener.stateUpdateHandler = { state in
      if case .ready = state, let port = listener.port { ready.yield(port) }
      if case .failed = state { ready.finish() }
    }
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
        [connection] data, _, _, _ in
        if data?.isEmpty == false { received.yield(connection) } else { received.finish() }
      }
    }
    listener.start(queue: queue)
    defer {
      listener.cancel()
      ready.finish()
      received.finish()
    }
    var portIterator = ports.makeAsyncIterator()
    let port = try #require(await portIterator.next())
    let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
    let exchange = AddressFamilyExchange(
      connection: connection, request: Data("GET / HTTP/1.1\r\n\r\n".utf8), timeout: 10)
    let task = Task { await exchange.run() }
    defer { task.cancel() }
    var peerIterator = peers.makeAsyncIterator()
    let peer = try #require(await peerIterator.next())
    defer { peer.cancel() }
    let start = ContinuousClock.now
    if cancelWhileWaiting {
      task.cancel()
      #expect(await task.value == nil)
      let closed = await withCheckedContinuation { continuation in
        peer.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, complete, error in
          continuation.resume(returning: complete || error != nil)
        }
      }
      #expect(closed)
    } else {
      peer.send(
        content: Data("fixture".utf8),
        completion: .contentProcessed { _ in peer.cancel() })
      #expect(await task.value == Data("fixture".utf8))
    }
    #expect(ContinuousClock.now - start < .seconds(2))
  }

  @Test func exchangeCancelledBeforeStartingReturnsImmediately() async {
    let connection = NWConnection(host: .ipv4(.loopback), port: .init(rawValue: 9)!, using: .tcp)
    let exchange = AddressFamilyExchange(connection: connection, request: Data(), timeout: 10)
    let start = ContinuousClock.now
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await exchange.run()
    }
    #expect(await task.value == nil)
    #expect(ContinuousClock.now - start < .seconds(2))
  }

  @Test(arguments: LocalIPQuery.Source.allCases)
  func rejectsInvalidOrInterceptedResponses(source: LocalIPQuery.Source) {
    for body in ["<html>blocked</html>", "{}", #"{"ip":"bad"}"#, "ip=bad\nloc=CN"] {
      #expect(LocalIPQuery.parse(Data(body.utf8), source: source) == nil)
    }
  }
}
