// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import Metrics

struct PublicAddressResponseTests {
  @Test func geoCacheEvictsOldestAndExpiredAddresses() async {
    let cache = PublicAddressLookup.GeoCache()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for index in 0..<100 {
      await cache.store(
        PublicAddressLookup.GeoInfo(), for: "192.0.2.\(index)",
        now: now.addingTimeInterval(Double(index)))
    }
    #expect(await cache.entries.count == 64)
    #expect(await cache.entries["192.0.2.0"] == nil)
    #expect(await cache.entries["192.0.2.99"] != nil)
    await cache.store(
      PublicAddressLookup.GeoInfo(), for: "198.51.100.1", now: now.addingTimeInterval(7200))
    #expect(await cache.entries.count == 1)
  }

  @Test func headIgnoresRepresentationLength() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ResponseFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "https://xstats-response.test/head")!)
    request.httpMethod = "HEAD"
    let (data, status) = await PublicAddressLookup.getWithStatus(request, session: session)
    #expect(data == Data() && status == 200)
  }

  @Test(arguments: [false, true]) func boundsUntrustedResponse(oversized: Bool) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ResponseFixture.self]
    let url = URL(string: "https://xstats-response.test/\(oversized ? "large" : "small")")!
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, status) = await PublicAddressLookup.getWithStatus(url, session: session)
    if oversized {
      #expect(data == nil && status == 0)
    } else {
      #expect(data == Data("ok".utf8) && status == 200)
    }
  }
}

private final class ResponseFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "xstats-response.test"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: url.path == "/head" ? ["Content-Length": "2097152"] : nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let data = url.path == "/large" ? Data(repeating: 65, count: 1_048_577) : Data("ok".utf8)
    if url.path != "/head" { client?.urlProtocol(self, didLoad: data) }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
