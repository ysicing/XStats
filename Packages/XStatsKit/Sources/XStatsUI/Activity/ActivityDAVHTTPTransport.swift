// SPDX-License-Identifier: AGPL-3.0-or-later

import ActivityDAVHTTP
import Foundation
import Network
import WebDAVSync
import os

actor ActivityDAVHTTPTransport {
  struct Tunnel: Sendable, Equatable {
    let interfaceName: String
    let localAddress: ActivityDAVIPAddress
  }

  struct Connection: Sendable {
    let url: URL
    let authority: String
    let tunnel: Tunnel?
  }

  typealias Resolve = @Sendable (String) async throws -> [String]
  typealias DiscoverTunnels = @Sendable () async throws -> [Tunnel]
  typealias Exchange = @Sendable (URLRequest, Connection, Int) async throws -> WebDAVResponse

  enum Failure: Error { case connect }

  private struct Route: Sendable {
    let address: ActivityDAVIPAddress
    let tunnel: Tunnel?
  }

  private let resolve: Resolve
  private let discoverTunnels: DiscoverTunnels
  private let exchange: Exchange
  private var verified: (ActivityDAVEndpoint, [Route])?

  init() {
    resolve = ActivityDAVDNSResolver.resolve
    discoverTunnels = Self.systemTunnels
    exchange = Self.systemExchange
  }

  init(
    resolve: @escaping Resolve, discoverTunnels: @escaping DiscoverTunnels,
    exchange: @escaping Exchange
  ) {
    self.resolve = resolve
    self.discoverTunnels = discoverTunnels
    self.exchange = exchange
  }

  func send(_ request: URLRequest, endpoint: ActivityDAVEndpoint, limit: Int) async throws
    -> WebDAVResponse
  {
    try Task.checkCancellation()
    guard endpoint.scheme == "http", let url = request.url, ActivityDAVEndpoint(url) == endpoint,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
      parts.query == nil, parts.fragment == nil, parts.percentEncodedPath.hasPrefix("/")
    else { throw ActivityDAVError.invalidAddress }
    if request.httpMethod == "PUT", request.value(forHTTPHeaderField: "If-None-Match") != "*" {
      let object = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        .suffix(2).map(String.init)
      guard request.value(forHTTPHeaderField: "If-None-Match") == nil,
        request.value(forHTTPHeaderField: "If-Match") == nil,
        request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream",
        ActivitySyncRemotePath.validMetadataObject(object)
      else { throw WebDAVError.transport }
      guard let payload = request.httpBody,
        payload.count <= ActivitySyncRemotePath.maximumMetadataBytes
      else { throw ActivitySyncFailure.limit }
    }
    let routes = try await routes(for: endpoint)
    let path = parts.percentEncodedPath
    let port = ":\(endpoint.port)"
    for route in routes {
      try Task.checkCancellation()
      guard
        let numericURL = URL(
          string: "http://\(route.address.urlHost)\(port)\(path)", encodingInvalidCharacters: false),
        ActivityDAVEndpoint(numericURL)?.host == route.address.text
      else { throw ActivityDAVError.invalidAddress }
      do {
        return try await exchange(
          request, Connection(url: numericURL, authority: endpoint.authority, tunnel: route.tunnel),
          limit)
      } catch Failure.connect {
        continue
      }
    }
    throw WebDAVError.transport
  }

  private func routes(for endpoint: ActivityDAVEndpoint) async throws -> [Route] {
    if let (origin, routes) = verified, origin == endpoint { return routes }
    let answers: [String]
    if ActivityDAVIPAddress(endpoint.host) != nil {
      answers = [endpoint.host]
    } else {
      answers = try await resolve(endpoint.host)
    }
    try Task.checkCancellation()
    guard answers.count <= ActivityDAVDNSResolver.maximumAddresses else {
      throw ActivitySyncFailure.limit
    }
    var candidates: [ActivityDAVIPAddress] = []
    var seen = Set<ActivityDAVIPAddress>()
    var network: ActivityDAVIPAddress.PrivateNetwork?
    for text in answers {
      guard let address = ActivityDAVIPAddress(text), let scope = address.network,
        network == nil || network == scope
      else { throw ActivityDAVError.invalidAddress }
      network = scope
      if seen.insert(address).inserted { candidates.append(address) }
    }
    guard let network, !candidates.isEmpty,
      !endpoint.host.hasSuffix(".ts.net") || network == .tailscale
    else { throw ActivityDAVError.invalidAddress }

    let approved: [Route]
    if network == .tailscale {
      let tunnels = try await discoverTunnels()
      try Task.checkCancellation()
      approved = candidates.compactMap { address in
        guard
          let tunnel = tunnels.first(where: {
            $0.localAddress.family == address.family && $0.localAddress.network == .tailscale
              && $0.interfaceName.hasPrefix("utun")
          })
        else { return nil }
        return Route(address: address, tunnel: tunnel)
      }
    } else {
      approved = candidates.map { Route(address: $0, tunnel: nil) }
    }
    guard !approved.isEmpty else { throw ActivityDAVError.invalidAddress }
    // 仓库实例只用于一轮同步，整轮使用同一组已验证的数值地址。
    verified = (endpoint, approved)
    return approved
  }

  private static func systemTunnels() async throws -> [Tunnel] {
    let monitor = NWPathMonitor(requiredInterfaceType: .other)
    let (paths, continuation) = AsyncStream<[NWInterface]>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    monitor.pathUpdateHandler = { path in
      continuation.yield(path.availableInterfaces)
      continuation.finish()
    }
    monitor.start(queue: .global(qos: .utility))
    defer { monitor.cancel() }
    let interfaces = await withTaskGroup(of: [NWInterface].self) { group in
      group.addTask {
        for await interfaces in paths { return interfaces }
        return []
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return []
      }
      let first = await group.next() ?? []
      group.cancelAll()
      return first
    }
    try Task.checkCancellation()
    guard !interfaces.isEmpty else { return [] }
    let probe = Task.detached(priority: .utility) {
      DashboardTailscaleEndpoint.discover(on: interfaces).sorted { $0.address < $1.address }
    }
    let endpoints = await withTaskCancellationHandler {
      await probe.value
    } onCancel: {
      probe.cancel()
    }
    try Task.checkCancellation()
    return endpoints.compactMap {
      guard let address = ActivityDAVIPAddress($0.address), address.network == .tailscale else {
        return nil
      }
      return Tunnel(interfaceName: $0.interface.name, localAddress: address)
    }
  }

  private static func systemExchange(
    _ request: URLRequest, _ connection: Connection, _ limit: Int
  ) async throws -> WebDAVResponse {
    guard let method = request.httpMethod,
      let authorization = request.value(forHTTPHeaderField: "Authorization")
    else { throw WebDAVError.transport }
    let replaceMetadata =
      method == "PUT" && request.value(forHTTPHeaderField: "If-None-Match") == nil
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let response = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<WebDAVResponse, any Error>) in
        DispatchQueue.global(qos: .utility).async {
          let payload = request.httpBody ?? Data()
          var status = 0
          var connectionFailed = false
          var oversized = false
          var data = Data()
          let receive: (UnsafePointer<UInt8>?, Int) -> Bool = { bytes, count in
            guard count <= limit - data.count else {
              oversized = true
              return false
            }
            if count > 0, let bytes { data.append(bytes, count: count) }
            return true
          }
          let isCancelled = { cancelled.withLock { $0 } }
          let url = connection.url.absoluteString
          let host = "Host: \(connection.authority)"
          let credentials = "Authorization: \(authorization)"
          let tunnel = connection.tunnel?.interfaceName ?? ""
          let localAddress = connection.tunnel?.localAddress.text ?? ""
          let success = payload.withUnsafeBytes { bytes in
            let body = bytes.bindMemory(to: UInt8.self).baseAddress
            if replaceMetadata {
              return ActivityDAVHTTPPutMetadata(
                url, host, credentials, body, payload.count, tunnel, localAddress,
                &status, &connectionFailed, receive, isCancelled)
            }
            return ActivityDAVHTTPPerform(
              url, method, host, credentials, body, payload.count, tunnel, localAddress,
              &status, &connectionFailed, receive, isCancelled)
          }
          if cancelled.withLock({ $0 }) {
            continuation.resume(throwing: CancellationError())
          } else if oversized {
            continuation.resume(throwing: ActivitySyncFailure.limit)
          } else if connectionFailed {
            continuation.resume(throwing: Failure.connect)
          } else if !success || !(100..<600).contains(status) {
            continuation.resume(throwing: WebDAVError.transport)
          } else {
            continuation.resume(returning: WebDAVResponse(data: data, status: status))
          }
        }
      }
      try Task.checkCancellation()
      return response
    } onCancel: {
      cancelled.withLock { $0 = true }
    }
  }
}
