// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import AIUsage

struct QuotaResponseTests {
  @Test(arguments: [false, true]) func boundsUntrustedResponse(oversized: Bool) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ResponseFixture.self]
    let url = URL(string: "https://xstats-response.test/\(oversized ? "large" : "small")")!
    let client = URLSessionQuotaHTTPClient(configuration: configuration)
    if oversized {
      await #expect(throws: (any Error).self) { try await client.send(URLRequest(url: url)) }
    } else {
      let (data, status) = try await client.send(URLRequest(url: url))
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
      url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let data = url.path == "/large" ? Data(repeating: 65, count: 1_048_577) : Data("ok".utf8)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
