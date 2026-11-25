// SPDX-License-Identifier: AGPL-3.0-or-later

import ActivityDAVHTTP
import Foundation
import Network
import os
import Testing

struct ActivityDAVHTTPWireTests {
  @Test(.timeLimit(.minutes(1)))
  func onlyMetadataPutOverwritesAndRedirectsStayOnTheWire() async throws {
    let name = String(repeating: "a", count: 64)
    let metadata = "/XStats/metadata/\(name)"
    let marker = "/XStats/dataset"
    let month = String(repeating: "b", count: 48)
    let shard = "/XStats/\(month)/\(month)/\(String(repeating: "c", count: 128))"
    let payload = Data(repeating: 0x61, count: 32)
    let queue = DispatchQueue(label: "ActivityDAVHTTPWireTests")
    let packets = OSAllocatedUnfairLock(initialState: [String]())
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    let (ports, ready) = AsyncStream<NWEndpoint.Port>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    listener.stateUpdateHandler = { [weak listener] state in
      switch state {
      case .ready:
        if let port = listener?.port { ready.yield(port) }
        ready.finish()
      case .failed, .cancelled: ready.finish()
      default: break
      }
    }
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      Self.receiveRequest(on: connection, prefix: Data(), bodyLength: payload.count) { request in
        let position = packets.withLock {
          $0.append(request)
          return $0.count
        }
        switch position {
        case 1, 2: return "412 Precondition Failed"
        case 3: return "204 No Content"
        case 4: return "307 Temporary Redirect\r\nLocation: /redirect-target"
        default: return "500 Unexpected Request"
        }
      }
    }
    listener.start(queue: queue)
    defer { listener.cancel() }
    var iterator = ports.makeAsyncIterator()
    let port = try #require(await iterator.next())
    let base = "http://127.0.0.1:\(port.rawValue)"
    try payload.withUnsafeBytes { bytes in
      let body = bytes.bindMemory(to: UInt8.self).baseAddress
      let receive: (UnsafePointer<UInt8>?, Int) -> Bool = { _, _ in false }
      let cancelled = { false }
      let host = "Host: fixture.test"
      let authorization = "Authorization: Basic Zml4dHVyZTpmaXh0dXJl"
      var status = 0
      var connectionFailed = false

      #expect(
        !ActivityDAVHTTPPutMetadata(
          base + marker, host, authorization, body, payload.count, "", "", &status,
          &connectionFailed, receive, cancelled))
      #expect(status == 0)
      #expect(
        !ActivityDAVHTTPPutMetadata(
          base + metadata, host, "X-Unexpected: fixture", body, payload.count, "", "", &status,
          &connectionFailed, receive, cancelled))
      #expect(status == 0)
      for path in [marker, shard] {
        try #require(
          ActivityDAVHTTPPerform(
            base + path, "PUT", host, authorization, body, payload.count, "", "", &status,
            &connectionFailed, receive, cancelled))
        #expect(status == 412)
      }
      for expected in [204, 307] {
        try #require(
          ActivityDAVHTTPPutMetadata(
            base + metadata, host, authorization, body, payload.count, "", "", &status,
            &connectionFailed, receive, cancelled))
        #expect(status == expected)
      }
    }
    let requests = packets.withLock { $0 }
    try #require(requests.count == 4)
    for (index, path) in [marker, shard, metadata, metadata].enumerated() {
      let request = requests[index]
      #expect(request.hasPrefix("PUT \(path) HTTP/1.1\r\n"))
      #expect(request.hasSuffix(String(decoding: payload, as: UTF8.self)))
      let headers = request.lowercased()
      #expect(headers.contains("\r\nif-none-match: *\r\n") == (index < 2))
      let mediaType = index < 2 ? "application/json" : "application/octet-stream"
      #expect(headers.contains("\r\ncontent-type: \(mediaType)\r\n"))
    }
  }

  private static func receiveRequest(
    on connection: NWConnection, prefix: Data, bodyLength: Int,
    respond: @escaping @Sendable (String) -> String
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      data, _, complete, error in
      guard let data, error == nil, prefix.count + data.count <= 8192 else {
        connection.cancel()
        return
      }
      let request = prefix + data
      let separator = Data("\r\n\r\n".utf8)
      if let end = request.range(of: separator)?.upperBound, request.count - end >= bodyLength {
        let status = respond(String(decoding: request, as: UTF8.self))
        connection.send(
          content: Data(
            "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
          completion: .contentProcessed { _ in connection.cancel() })
      } else if !complete {
        receiveRequest(on: connection, prefix: request, bodyLength: bodyLength, respond: respond)
      } else {
        connection.cancel()
      }
    }
  }
}
