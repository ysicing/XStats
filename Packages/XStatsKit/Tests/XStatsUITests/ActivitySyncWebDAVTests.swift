// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import os
import Testing
import WebDAVSync
@testable import XStatsUI

private final class ActivityDAVProtocol: URLProtocol, @unchecked Sendable {
  struct Exchange: Sendable {
    let method: String
    let path: String
    let status: Int
    var body = Data()
    var location: String?
  }

  struct Script: Sendable {
    let exchanges: [Exchange]
    var requests = 0
    var mismatches: [String] = []
  }

  static let scripts = OSAllocatedUnfairLock(initialState: [String: Script]())
  static let authorization =
    "Basic " + Data("fixture-user:fixture-secret".utf8).base64EncodedString()

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let host = url.host,
      let exchange = Self.scripts.withLock({ scripts -> Exchange? in
        guard var script = scripts[host] else { return nil }
        let index = script.requests
        script.requests += 1
        scripts[host] = script
        return index < script.exchanges.count ? script.exchanges[index] : nil
      })
    else {
      Issue.record("Unexpected WebDAV request")
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }

    var mismatches: [String] = []
    if request.httpMethod != exchange.method { mismatches.append("method for \(exchange.path)") }
    if URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath != exchange.path {
      mismatches.append("path for \(exchange.method) \(exchange.path)")
    }
    if url.scheme != "https" { mismatches.append("HTTPS scheme") }
    let requiredHeaders: [String: String?] = [
      "Authorization": Self.authorization,
      "If-None-Match": exchange.method == "PUT" ? "*" : nil,
      "Depth": exchange.method == "PROPFIND" ? "1" : nil,
      "Content-Type": exchange.method == "PUT"
        ? "application/json"
        : exchange.method == "PROPFIND" ? "application/xml; charset=utf-8" : nil,
    ]
    for (name, expected) in requiredHeaders
    where request.value(forHTTPHeaderField: name) != expected {
      mismatches.append("\(name) for \(exchange.method) \(exchange.path)")
    }
    if !mismatches.isEmpty {
      let failures = mismatches
      Self.scripts.withLock { $0[host]?.mismatches.append(contentsOf: failures) }
    }

    var headers = ["Content-Length": String(exchange.body.count)]
    if let location = exchange.location { headers["Location"] = location }
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: exchange.status, httpVersion: "HTTP/1.1", headerFields: headers
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !exchange.body.isEmpty { client?.urlProtocol(self, didLoad: exchange.body) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

struct ActivitySyncWebDAVTests {
  private let root = "/share/XStats/"

  @Test func createsCollectionsPublishesConditionallyAndReadsThroughURLSession() async throws {
    let data = Data("fixture shard bytes".utf8)
    let monthToken = String(repeating: "a", count: 48)
    let dayToken = String(repeating: "b", count: 48)
    let objectToken = String(repeating: "c", count: 128)
    let month = root + monthToken + "/"
    let day = month + dayToken + "/"
    let file = day + objectToken
    let path = [monthToken, dayToken, objectToken]
    let listing = Data(
      """
      <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>\(day)</d:href></d:response>
        <d:response><d:href>\(file)</d:href></d:response>
        <d:response><d:href>https://other.test\(file)</d:href></d:response>
      </d:multistatus>
      """.utf8)
    try await withDAV([
      .init(method: "PROPFIND", path: root, status: 404),
      .init(method: "PUT", path: file, status: 404),
      .init(method: "MKCOL", path: root, status: 405),
      .init(method: "MKCOL", path: month, status: 201),
      .init(method: "MKCOL", path: day, status: 201),
      .init(method: "PUT", path: file, status: 201),
      .init(method: "PROPFIND", path: day, status: 207, body: listing),
      .init(method: "GET", path: file, status: 200, body: data),
      .init(method: "PUT", path: file, status: 412),
      .init(method: "GET", path: file, status: 404),
    ]) { (dav: ActivitySyncWebDAV) async throws in
      let emptyListing = try await dav.list([])
      #expect(emptyListing.isEmpty)
      let created = try await dav.create(data, at: path)
      #expect(created)
      let objects = try await dav.list([monthToken, dayToken])
      #expect(objects == [objectToken])
      let stored = try await dav.read(path)
      #expect(stored == data)
      let createdAgain = try await dav.create(data, at: path)
      #expect(createdAgain == false)
      let missing = try await dav.read(path)
      #expect(missing == nil)
    }
  }

  @Test(arguments: [201, 405])
  func initializesDirectlyConfiguredDatasetRoot(_ collectionStatus: Int) async throws {
    let file = root + ActivitySyncRemotePath.marker
    let data = Data("fixture dataset marker".utf8)
    try await withDAV(
      [
        .init(method: "PUT", path: file, status: 409),
        .init(method: "MKCOL", path: root, status: collectionStatus),
        .init(method: "PUT", path: file, status: 201),
      ], basePath: root
    ) { dav in
      let created = try await dav.create(data, at: [ActivitySyncRemotePath.marker])
      #expect(created)
    }
  }

  @Test func listsMetadataUnderPercentEncodedBaseAndRejectsUnrelatedHrefs() async throws {
    let base = "/share/100%25/caf%C3%A9/"
    let directory = base + "XStats/metadata/"
    let listedDirectory = "/share/100%25/caf%c3%a9/XStats/metadata/"
    let fullPathName = String(repeating: "a", count: 64)
    let relativeName = String(repeating: "b", count: 64)
    let rejected = String(repeating: "c", count: 64)
    let hrefs = [
      listedDirectory + fullPathName,
      relativeName,
      "https://other.test" + directory + rejected,
      "/share/100%25/caf%C3%A9/XStats/metadata-copy/" + rejected,
      "/share/100%2525/caf%C3%A9/XStats/metadata/" + rejected,
      directory + "nested/" + rejected,
      directory + "%2e/" + rejected,
      directory + "%2F" + rejected,
      directory + "%5C" + rejected,
      directory + "%2563" + String(rejected.dropFirst()),
      directory + rejected + "/",
      directory + rejected + "?query=1",
      directory + rejected + "#fragment",
    ]
    let responses = hrefs.map { "<response><href>\($0)</href></response>" }.joined()
    let listing = Data("<multistatus xmlns=\"DAV:\">\(responses)</multistatus>".utf8)
    try await withDAV(
      [
        .init(method: "PROPFIND", path: directory, status: 207, body: listing)
      ], basePath: base
    ) { dav in
      let names = try await dav.list([ActivitySyncRemotePath.metadata])
      #expect(names == [fullPathName, relativeName])
    }
  }

  @Test func reportsAuthenticationFailureAndRefusesRedirectResponses() async throws {
    try await withDAV([
      .init(method: "PROPFIND", path: root, status: 401),
      .init(
        method: "PROPFIND", path: root, status: 307,
        location: "https://other.test/share/"),
    ]) { dav in
      await #expect(throws: WebDAVError.unauthorized) { try await dav.list([]) }
      await #expect(throws: WebDAVError.redirect) { try await dav.list([]) }
    }
  }

  @Test func productionRedirectDelegateRejectsSameAndCrossOriginTargets() async throws {
    let url = try #require(URL(string: "https://fixture.test/share/"))
    let options = URLSessionConfiguration.ephemeral
    options.protocolClasses = [ActivityDAVProtocol.self]
    let session = URLSession(configuration: options)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: url)
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
    for target in ["https://fixture.test/other/", "https://other.test/share/"] {
      let redirected = try #require(URL(string: target))
      let result = await ActivitySyncWebDAV.NoRedirect().urlSession(
        session, task: task, willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: redirected))
      #expect(result == nil)
    }
  }

  @Test func privateHTTPConfigurationKeepsCredentialsSeparateAndLegacySettingsHTTPSOnly() throws {
    let existing = try WebDAVConfiguration(
      address: "https://nas.local/share/", username: "fixture-user")
    let https = try ActivityDAVConfiguration(
      address: "https://nas.local/share/", username: "fixture-user")
    let http = try ActivityDAVConfiguration(
      address: "http://NAS.local/share//", username: "fixture-user")
    let ipv4 = try ActivityDAVConfiguration(
      address: "http://192.168.3.2:8080", username: "fixture-user")
    let ipv6 = try ActivityDAVConfiguration(
      address: "http://[fd12::2]:8080/share", username: "fixture-user")

    #expect(https.directoryURL == existing.directoryURL)
    #expect(https.credentialAccount == existing.credentialAccount)
    #expect(http.directoryURL.absoluteString == "http://nas.local/share/")
    #expect(http.credentialAccount != https.credentialAccount)
    #expect(ipv4.endpoint.authority == "192.168.3.2:8080")
    #expect(ipv6.endpoint.authority == "[fd12::2]:8080")
    #expect(throws: WebDAVError.invalidAddress) {
      try WebDAVConfiguration(address: http.directoryURL.absoluteString, username: "fixture-user")
    }
  }

  @Test(arguments: [
    "http://user@192.168.2.3/", "http://@nas.local/", "http://nas.local%40other.local/",
    "http://192.168.002.003/", "http://0xC0A80102/", "http://192.168.1.2./",
    "http://192.168.1/", "http://198.51.100.4/", "http://127.0.0.1/",
    "http://[::ffff:192.168.2.3]/", "http://[fe80::1%25en0]/", "http://[fe80::1]/",
    "http://nas.local:0/", "http://nas.local:65536/", "http://nas.local/a%2fb/",
    "http://nas.local/a/%2e%2e/", "http://nas.local/share?extra=1",
  ])
  func configurationRejectsAmbiguousOrDisallowedAddresses(_ address: String) {
    #expect(throws: ActivityDAVError.invalidAddress) {
      try ActivityDAVConfiguration(address: address, username: "fixture-user")
    }
  }

  @Test func connectsToNumericLANAddressButChecksHrefAgainstConfiguredOrigin() async throws {
    let config = try ActivityDAVConfiguration(
      address: "http://nas.local:8080/share/", username: "fixture-user")
    let valid = ActivitySyncRemotePath.marker
    let other = String(repeating: "a", count: 48)
    let listing = Data(
      """
      <multistatus xmlns="DAV:">
        <response><href>http://nas.local:8080\(root)\(valid)</href></response>
        <response><href>http://192.168.2.3:8080\(root)\(other)/</href></response>
        <response><href>https://nas.local:8080\(root)\(other)/</href></response>
        <response><href>http://nas.local:8081\(root)\(other)/</href></response>
        <response><href>http://user@nas.local:8080\(root)\(other)/</href></response>
      </multistatus>
      """.utf8)
    let expectedPath = root
    let transport = ActivityDAVHTTPTransport(
      resolve: { host in
        #expect(host == "nas.local")
        return ["192.168.2.3", "fd12::4"]
      },
      discoverTunnels: {
        Issue.record("LAN addresses must not discover Tailscale tunnels")
        return []
      },
      exchange: { request, connection, _ in
        #expect(connection.authority == "nas.local:8080")
        #expect(connection.tunnel == nil)
        #expect(
          request.value(forHTTPHeaderField: "Authorization") == ActivityDAVProtocol.authorization)
        #expect(connection.url.absoluteString == "http://192.168.2.3:8080\(expectedPath)")
        return WebDAVResponse(data: listing, status: 207)
      })
    let dav = ActivitySyncWebDAV(
      configuration: config, password: "fixture-secret", httpTransport: transport)
    let children = try await dav.list([])
    #expect(children == [valid])
  }

  @Test(arguments: [
    ["93.184.216.34"], ["192.168.2.3", "2606:4700::1"], ["93.184.216.34", "fd12::4"],
    ["100.73.1.2", "192.168.2.3"], ["192.168.2.3", "::ffff:192.168.2.3"], [],
  ])
  func rejectsWholeResolutionBeforeSendingCredentials(_ answers: [String]) async throws {
    let config = try ActivityDAVConfiguration(
      address: "http://nas.local/share/", username: "fixture-user")
    let transport = ActivityDAVHTTPTransport(
      resolve: { _ in answers },
      discoverTunnels: { [] },
      exchange: { _, _, _ in
        Issue.record("Rejected destinations must not receive a request")
        throw WebDAVError.transport
      })
    let dav = ActivitySyncWebDAV(
      configuration: config, password: "fixture-secret", httpTransport: transport)
    await #expect(throws: ActivityDAVError.invalidAddress) { try await dav.list([]) }
  }

  @Test func oversizedResolutionIsRejectedBeforeConnecting() async throws {
    let config = try ActivityDAVConfiguration(
      address: "http://nas.local/share/", username: "fixture-user")
    let answers = (0...ActivityDAVDNSResolver.maximumAddresses).map { "192.168.2.\($0 + 1)" }
    let transport = ActivityDAVHTTPTransport(
      resolve: { _ in answers },
      discoverTunnels: { [] },
      exchange: { _, _, _ in
        Issue.record("An oversized DNS result must not reach the transport")
        throw WebDAVError.transport
      })
    let dav = ActivitySyncWebDAV(
      configuration: config, password: "fixture-secret", httpTransport: transport)
    await #expect(throws: ActivitySyncFailure.limit) { try await dav.list([]) }
  }

  @Test func magicDNSUsesAnApprovedTunnelAndHTTPRedirectIsNeverRetried() async throws {
    let config = try ActivityDAVConfiguration(
      address: "http://dav.tail1234.ts.net/share/", username: "fixture-user")
    let localAddress = try #require(ActivityDAVIPAddress("fd7a:115c:a1e0::2"))
    let tunnel = ActivityDAVHTTPTransport.Tunnel(interfaceName: "utun7", localAddress: localAddress)
    let requests = OSAllocatedUnfairLock(initialState: 0)
    let transport = ActivityDAVHTTPTransport(
      resolve: { _ in ["100.73.1.2", "fd7a:115c:a1e0::3"] },
      discoverTunnels: { [tunnel] },
      exchange: { request, connection, _ in
        requests.withLock { $0 += 1 }
        #expect(ActivityDAVEndpoint(connection.url)?.host == "fd7a:115c:a1e0::3")
        #expect(connection.authority == "dav.tail1234.ts.net")
        #expect(connection.tunnel == tunnel)
        #expect(request.httpMethod == "PROPFIND")
        return WebDAVResponse(data: Data(), status: 307)
      })
    let dav = ActivitySyncWebDAV(
      configuration: config, password: "fixture-secret", httpTransport: transport)
    await #expect(throws: WebDAVError.redirect) { try await dav.list([]) }
    #expect(requests.withLock { $0 } == 1)
  }

  @Test func tailnetAddressesAreRejectedWithoutAVerifiedTunnel() async throws {
    let config = try ActivityDAVConfiguration(
      address: "http://100.73.1.2/share", username: "fixture-user")
    let transport = ActivityDAVHTTPTransport(
      resolve: { _ in
        Issue.record("Numeric addresses must not enter DNS")
        return []
      },
      discoverTunnels: { [] },
      exchange: { _, _, _ in
        Issue.record("A Tailscale address without a tunnel must not receive credentials")
        throw WebDAVError.transport
      })
    let dav = ActivitySyncWebDAV(
      configuration: config, password: "fixture-secret", httpTransport: transport)
    await #expect(throws: ActivityDAVError.invalidAddress) { try await dav.list([]) }
  }

  private func withDAV(
    _ exchanges: [ActivityDAVProtocol.Exchange],
    basePath: String = "/share/",
    _ operation: (ActivitySyncWebDAV) async throws -> Void
  ) async throws {
    let host = "sync-\(UUID().uuidString.lowercased()).test"
    ActivityDAVProtocol.scripts.withLock { $0[host] = .init(exchanges: exchanges) }
    defer {
      let script = ActivityDAVProtocol.scripts.withLock { $0.removeValue(forKey: host) }
      #expect(script?.requests == exchanges.count)
      if let mismatches = script?.mismatches, !mismatches.isEmpty {
        Issue.record("Unexpected request properties: \(mismatches.joined(separator: ", "))")
      }
    }
    let configuration = try ActivityDAVConfiguration(
      address: "https://\(host)\(basePath)", username: "fixture-user")
    let dav = ActivitySyncWebDAV(configuration: configuration, password: "fixture-secret") {
      let options = URLSessionConfiguration.ephemeral
      options.protocolClasses = [ActivityDAVProtocol.self]
      return options
    }
    try await operation(dav)
  }
}
