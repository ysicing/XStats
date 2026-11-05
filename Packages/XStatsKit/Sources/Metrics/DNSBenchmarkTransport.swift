// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network
import Security

actor DNSBenchmarkClient {
  private let target: DNSBenchmarkTarget
  private let timeout: TimeInterval
  private var socket: DNSBenchmarkSocket?
  private var session: URLSession?
  private var handshake: Double?

  init(target: DNSBenchmarkTarget, timeout: TimeInterval) {
    self.target = target
    self.timeout = timeout
  }

  func close() {
    socket?.cancel()
    socket = nil
    session?.invalidateAndCancel()
    session = nil
  }

  func query(_ domain: String) async throws -> DNSBenchmarkSample {
    try Task.checkCancellation()
    let query = try DNSBenchmarkWire.query(domain: domain, id: .random(in: 0...UInt16.max))
    do {
      if target.transport == .doh { return try await https(query) }
      let deadline = ContinuousClock.now + .seconds(timeout)
      let connection: DNSBenchmarkSocket
      if let socket {
        connection = socket
      } else {
        connection = try DNSBenchmarkSocket(target: target)
        socket = connection
        let started = ContinuousClock.now
        try await connection.start(deadline: deadline)
        if target.transport != .udp {
          handshake = SpeedConnection.milliseconds(ContinuousClock.now - started)
        }
      }
      try Task.checkCancellation()
      let started = ContinuousClock.now
      let response: Data
      if target.transport == .udp {
        try await connection.send(query, deadline: deadline)
        response = try await connection.receiveMessage(deadline: deadline)
      } else {
        let framed = Data([UInt8(query.count >> 8), UInt8(query.count & 255)]) + query
        try await connection.send(framed, deadline: deadline)
        let prefix = try await connection.receive(count: 2, deadline: deadline)
        let length = Int(prefix[prefix.startIndex]) << 8 | Int(prefix[prefix.startIndex + 1])
        guard length >= 12 else { throw DNSBenchmarkFailure.invalidResponse }
        response = try await connection.receive(count: length, deadline: deadline)
      }
      let elapsed = SpeedConnection.milliseconds(ContinuousClock.now - started)
      let addresses = try DNSBenchmarkWire.addresses(in: response, query: query)
      try Task.checkCancellation()
      return DNSBenchmarkSample(
        milliseconds: elapsed, handshakeMilliseconds: handshake, addresses: addresses)
    } catch {
      close()
      try Task.checkCancellation()
      if (error as? URLError)?.code == .timedOut { throw DNSBenchmarkFailure.timeout }
      throw error
    }
  }

  private func https(_ query: Data) async throws -> DNSBenchmarkSample {
    guard let url = target.httpsURL, url.scheme == "https" else {
      throw DNSBenchmarkFailure.invalidResponse
    }
    let session: URLSession
    if let existing = self.session {
      session = existing
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.urlCredentialStorage = nil
      configuration.waitsForConnectivity = false
      configuration.timeoutIntervalForRequest = timeout
      configuration.timeoutIntervalForResource = timeout
      session = URLSession(configuration: configuration)
      self.session = session
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.httpBody = query
    request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
    request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    let metrics = DNSBenchmarkHTTPMetrics()
    let (bytes, response) = try await session.bytes(for: request, delegate: metrics)
    defer { bytes.task.cancel() }
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.mimeType?.lowercased() == "application/dns-message",
      response.expectedContentLength <= 65_535
    else { throw DNSBenchmarkFailure.invalidResponse }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < 65_535 else { throw DNSBenchmarkFailure.invalidResponse }
      data.append(byte)
    }
    let addresses = try DNSBenchmarkWire.addresses(in: data, query: query)
    let timing = await metrics.timing()
    try Task.checkCancellation()
    guard let timing else { throw DNSBenchmarkFailure.connection }
    if let measuredHandshake = timing.handshake { handshake = measuredHandshake }
    return DNSBenchmarkSample(
      milliseconds: timing.query, handshakeMilliseconds: handshake, addresses: addresses)
  }
}

private final class DNSBenchmarkSocket: Sendable {
  private let connection: NWConnection
  private static let queue = DispatchQueue(label: "work.12306.xstats.dns", qos: .utility)

  init(target: DNSBenchmarkTarget) throws {
    guard let port = NWEndpoint.Port(rawValue: target.port) else {
      throw DNSBenchmarkFailure.connection
    }
    let parameters: NWParameters
    if target.transport == .udp {
      parameters = .udp
    } else {
      let tcp = NWProtocolTCP.Options()
      tcp.noDelay = true
      var tls: NWProtocolTLS.Options?
      if target.transport == .dot {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(
          options.securityProtocolOptions, target.tlsServerName ?? target.host)
        tls = options
      }
      parameters = NWParameters(tls: tls, tcp: tcp)
    }
    connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: parameters)
  }

  func cancel() { connection.cancel() }

  func start(deadline: ContinuousClock.Instant) async throws {
    let _: Bool = try await wait(deadline: deadline) { [connection] gate in
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: gate.resume(.success(true))
        case .failed, .waiting, .cancelled: gate.resume(.failure(.connection))
        default: break
        }
      }
      connection.start(queue: Self.queue)
    }
    connection.stateUpdateHandler = nil
  }

  func send(_ data: Data, deadline: ContinuousClock.Instant) async throws {
    let _: Bool = try await wait(deadline: deadline) { [connection] gate in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          gate.resume(error == nil ? .success(true) : .failure(.connection))
        })
    }
  }

  func receiveMessage(deadline: ContinuousClock.Instant) async throws -> Data {
    try await wait(deadline: deadline) { [connection] gate in
      connection.receiveMessage { data, _, _, error in
        guard error == nil, let data else {
          gate.resume(.failure(.connection))
          return
        }
        gate.resume(.success(data))
      }
    }
  }

  func receive(count: Int, deadline: ContinuousClock.Instant) async throws -> Data {
    var result = Data()
    while result.count < count {
      try Task.checkCancellation()
      let remaining = count - result.count
      let data: Data = try await wait(deadline: deadline) { [connection] gate in
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
          data, _, _, error in
          guard error == nil, let data, !data.isEmpty else {
            gate.resume(.failure(.connection))
            return
          }
          gate.resume(.success(data))
        }
      }
      result.append(data)
    }
    return result
  }

  private func wait<Value: Sendable>(
    deadline: ContinuousClock.Instant,
    begin: (ContinuationGate<Result<Value, DNSBenchmarkFailure>>) -> Void
  ) async throws -> Value {
    try Task.checkCancellation()
    let gate = ContinuationGate<Result<Value, DNSBenchmarkFailure>>()
    let timer = Task { [connection] in
      do {
        try await Task.sleep(until: deadline, clock: .continuous)
        gate.resume(.failure(.timeout))
        connection.cancel()
      } catch {}
    }
    defer { timer.cancel() }
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        gate.attach(continuation)
        if Task.isCancelled {
          gate.resume(.failure(.cancelled))
        } else {
          begin(gate)
        }
      }
    } onCancel: { [connection] in
      gate.resume(.failure(.cancelled))
      connection.cancel()
    }
    try Task.checkCancellation()
    return try result.get()
  }
}

private final class DNSBenchmarkHTTPMetrics: NSObject, URLSessionTaskDelegate, Sendable {
  struct Timing: Sendable {
    let query: Double
    let handshake: Double?
  }
  private let gate = ContinuationGate<Timing?>()

  func timing() async -> Timing? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { gate.attach($0) }
    } onCancel: { [gate] in
      gate.resume(nil)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    guard let transaction = metrics.transactionMetrics.last,
      let start = transaction.requestStartDate, let end = transaction.responseEndDate
    else {
      gate.resume(nil)
      return
    }
    let handshake: Double?
    if let connect = transaction.connectStartDate, let ready = transaction.connectEndDate {
      handshake = max(0, ready.timeIntervalSince(connect) * 1000)
    } else {
      handshake = nil
    }
    gate.resume(Timing(query: max(0, end.timeIntervalSince(start) * 1000), handshake: handshake))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    // 回调顺序不保证 didFinishCollecting 先于 didCompleteWithError；立即收口会用 nil 覆盖尚未到达的耗时。
    // 这里仅在短暂宽限后仍无 metrics 时才收口，gate 只接受第一次结果。
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
      [gate] in
      gate.resume(nil)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
