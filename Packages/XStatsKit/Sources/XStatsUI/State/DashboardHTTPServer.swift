// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network

enum DashboardPeer: Equatable {
  case loopback, local
  case tailscale(NWEndpoint.Host)

  static func isTailscaleAddress(_ host: NWEndpoint.Host) -> Bool {
    switch host {
    case .ipv4(let address):
      let bytes = address.rawValue
      return bytes[0] == 100 && (64...127).contains(bytes[1])
    case .ipv6(let address):
      if let mapped = address.asIPv4 { return isTailscaleAddress(.ipv4(mapped)) }
      return address.rawValue.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
    default:
      return false
    }
  }

  init?(_ host: NWEndpoint.Host) {
    switch host {
    case .ipv4(let address):
      let bytes = address.rawValue
      if address.isLoopback {
        self = .loopback
      } else if bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
        || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
      {
        self = .local
      } else {
        return nil
      }
    case .ipv6(let address):
      if address.isLoopback {
        self = .loopback
      } else if let mapped = address.asIPv4 {
        self.init(.ipv4(mapped))
      } else if address.isLinkLocal || (address.rawValue[0] & 0xfe) == 0xfc {
        self = .local
      } else {
        return nil
      }
    case .name:
      return nil
    @unknown default:
      return nil
    }
  }

  static func authority(
    _ authority: String, port: UInt16, tailscaleHost: NWEndpoint.Host? = nil
  ) -> Self? {
    let suffix = ":\(port)"
    let host: String
    if authority.hasSuffix(suffix) {
      host = String(authority.dropLast(suffix.count))
    } else if port == 80 {
      host = authority
    } else {
      return nil
    }
    if host.lowercased() == "localhost" { return .loopback }
    let numericHost: NWEndpoint.Host
    if let address = IPv4Address(host) {
      numericHost = .ipv4(address)
    } else if host.hasPrefix("["), host.hasSuffix("]"),
      let address = IPv6Address(String(host.dropFirst().dropLast()))
    {
      numericHost = .ipv6(address)
    } else {
      return nil
    }
    if numericHost == tailscaleHost { return .tailscale(numericHost) }
    return Self(numericHost)
  }
}

struct DashboardHTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  var body = Data()
}

struct DashboardHTTPResponse {
  let status: Int
  var type = "text/plain; charset=utf-8"
  var body = Data()
  var allow: String?
  var appLanguage: String?

  var wireData: Data {
    let reason =
      switch status {
      case 200: "OK"
      case 202: "Accepted"
      case 400: "Bad Request"
      case 403: "Forbidden"
      case 404: "Not Found"
      case 405: "Method Not Allowed"
      case 413: "Content Too Large"
      case 415: "Unsupported Media Type"
      default: "Internal Server Error"
      }
    var headers = [
      "HTTP/1.1 \(status) \(reason)", "Connection: close", "Cache-Control: no-store",
      "Content-Type: \(type)", "Content-Length: \(body.count)", "X-Content-Type-Options: nosniff",
      "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
    ]
    if let allow { headers.append("Allow: \(allow)") }
    if let appLanguage { headers.append("X-XStats-Language: \(appLanguage)") }
    var data = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    data.append(body)
    return data
  }
}

struct DashboardHTTPParser {
  static let headerLimit = 8192
  static let bodyLimit = 16_384
  private static let separator = Data([13, 10, 13, 10])

  enum Outcome {
    case incomplete
    case rejected(Int)
    case request(DashboardHTTPRequest)
  }

  private var buffer = Data()
  private var head: DashboardHTTPRequest?
  private var bodyLength = 0

  mutating func append(_ data: Data) -> Outcome {
    buffer.append(data)
    if head == nil {
      guard let separator = buffer.range(of: Self.separator) else {
        return buffer.count >= Self.headerLimit ? .rejected(413) : .incomplete
      }
      guard separator.upperBound <= Self.headerLimit else { return .rejected(413) }
      guard let text = String(data: buffer[..<separator.lowerBound], encoding: .ascii) else {
        return .rejected(400)
      }
      let lines = text.components(separatedBy: "\r\n")
      let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
      guard request.count == 3, !request[0].isEmpty, request[1].hasPrefix("/"),
        request[2] == "HTTP/1.1",
        !text.unicodeScalars.contains(where: {
          $0.value < 32 && $0 != "\r" && $0 != "\n" && $0 != "\t" || $0.value == 127
        })
      else { return .rejected(400) }
      var headers: [String: String] = [:]
      for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { return .rejected(400) }
        let key = line[..<colon].lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
          key.utf8.allSatisfy({
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
          }), !value.contains("\r"), !value.contains("\n")
        else { return .rejected(400) }
        // 单请求单连接，拒绝有歧义的请求体与访问控制头。
        if [
          "host", "origin", "content-length", "content-type", "mcp-protocol-version",
          "sec-fetch-site", "transfer-encoding",
        ].contains(key), headers[key] != nil {
          return .rejected(400)
        }
        headers[key] = value
      }
      guard headers["host"] != nil, headers["transfer-encoding"] == nil else {
        return .rejected(400)
      }
      if let length = headers["content-length"] {
        guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }) else {
          return .rejected(400)
        }
        guard let count = Int(length), count <= Self.bodyLimit else { return .rejected(413) }
        bodyLength = count
      }
      head = DashboardHTTPRequest(
        method: String(request[0]), path: String(request[1]), headers: headers)
      buffer = Data(buffer[separator.upperBound...])
    }
    guard buffer.count >= bodyLength, var request = head else { return .incomplete }
    guard buffer.count == bodyLength else { return .rejected(400) }
    request.body = buffer
    return .request(request)
  }
}

@MainActor
final class DashboardHTTPServer {
  typealias Handler =
    @MainActor (DashboardHTTPRequest, DashboardPeer) async -> DashboardHTTPResponse

  private let listener: NWListener
  private let tailscaleEndpoint: DashboardTailscaleEndpoint?
  private var clients: [ObjectIdentifier: DashboardHTTPClient] = [:]
  private var isStopped = false

  var boundPort: UInt16? {
    guard let port = listener.port?.rawValue, port > 0 else { return nil }
    return port
  }

  init(port: UInt16, tailscaleEndpoint: DashboardTailscaleEndpoint? = nil) throws {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      throw NWError.posix(.EINVAL)
    }
    self.tailscaleEndpoint = tailscaleEndpoint
    let parameters = NWParameters.tcp
    // 让绑定具体隧道接口的监听与原局域网监听共享用户配置的端口。
    parameters.allowLocalEndpointReuse = true
    if let tailscaleEndpoint {
      parameters.requiredInterface = tailscaleEndpoint.interface
      parameters.requiredLocalEndpoint = .hostPort(host: tailscaleEndpoint.host, port: endpointPort)
      listener = try NWListener(using: parameters)
    } else {
      parameters.acceptLocalOnly = true
      parameters.prohibitedInterfaceTypes = [.cellular, .other]
      listener = try NWListener(using: parameters, on: endpointPort)
    }
  }

  func start(onState: @escaping @MainActor (NWListener.State) -> Void, handle: @escaping Handler) {
    // Network.framework 将这些回调投递到 start 指定的主队列。
    listener.stateUpdateHandler = { state in MainActor.assumeIsolated { onState(state) } }
    listener.newConnectionHandler = { [weak self] connection in
      MainActor.assumeIsolated {
        guard let self, !self.isStopped, self.clients.count < 16,
          case .hostPort(let host, _) = connection.endpoint
        else {
          connection.cancel()
          return
        }
        let peer: DashboardPeer?
        if let endpoint = self.tailscaleEndpoint {
          peer = DashboardPeer.isTailscaleAddress(host) ? .tailscale(endpoint.host) : nil
        } else {
          peer = DashboardPeer(host)
        }
        guard let peer else {
          connection.cancel()
          return
        }
        let id = ObjectIdentifier(connection)
        let client = DashboardHTTPClient(connection: connection)
        self.clients[id] = client
        client.start(
          handle: { await handle($0, peer) },
          finished: { [weak self] in self?.clients.removeValue(forKey: id) })
      }
    }
    listener.start(queue: .main)
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    listener.newConnectionHandler = nil
    listener.stateUpdateHandler = nil
    listener.cancel()
    let active = clients.values
    clients.removeAll()
    for client in active { client.stop() }
  }
}

@MainActor
private final class DashboardHTTPClient {
  private let connection: NWConnection
  private var parser = DashboardHTTPParser()
  private var deadline: Task<Void, Never>?
  private var response: Task<Void, Never>?
  private var finished: (() -> Void)?

  init(connection: NWConnection) { self.connection = connection }

  func start(
    handle: @escaping @MainActor (DashboardHTTPRequest) async -> DashboardHTTPResponse,
    finished: @escaping () -> Void
  ) {
    self.finished = finished
    deadline = Task { [weak self] in
      try? await Task.sleep(for: .seconds(8), tolerance: .milliseconds(250))
      if !Task.isCancelled { self?.stop() }
    }
    connection.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        switch state {
        case .failed, .cancelled: self?.stop()
        default: break
        }
      }
    }
    connection.start(queue: .main)
    receive(handle)
  }

  private func receive(
    _ handle: @escaping @MainActor (DashboardHTTPRequest) async -> DashboardHTTPResponse
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, complete, error in
      MainActor.assumeIsolated {
        guard let self, self.finished != nil else { return }
        guard error == nil else {
          self.stop()
          return
        }
        switch self.parser.append(data ?? Data()) {
        case .incomplete:
          if complete { self.stop() } else { self.receive(handle) }
        case .rejected(let status):
          self.send(DashboardHTTPResponse(status: status))
        case .request(let request):
          self.response = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let response = await handle(request)
            if !Task.isCancelled { self?.send(response) }
          }
        }
      }
    }
  }

  private func send(_ response: DashboardHTTPResponse) {
    connection.send(
      content: response.wireData, contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { [weak self] _ in
        MainActor.assumeIsolated { self?.stop() }
      })
  }

  func stop() {
    guard let finished else { return }
    self.finished = nil
    deadline?.cancel()
    response?.cancel()
    connection.cancel()
    finished()
  }
}
