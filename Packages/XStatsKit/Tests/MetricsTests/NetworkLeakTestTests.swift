// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics

struct NetworkLeakTestTests {
  @Test func candidatesUseAddressFieldAndComparableFamilies() throws {
    let candidate = try #require(
      NetworkLeakTest.candidate(
        "candidate:1234 1 udp 100 2001:db8::1 5000 typ srflx raddr 192.168.1.2 rport 4000"))
    #expect(candidate.address == "2001:db8::1")
    #expect(NetworkLeakTest.matchesExit(candidate, exit: "2001:0db8:0:0:0:0:0:1") == true)
    #expect(NetworkLeakTest.matchesExit(candidate, exit: "2001:db8::2") == false)
    #expect(NetworkLeakTest.matchesExit(candidate, exit: "192.0.2.1") == nil)
    #expect(NetworkLeakTest.matchesExit(candidate, exit: nil) == nil)
    let mdns = try #require(
      NetworkLeakTest.candidate("candidate:a 1 udp 100 abc-123.local 5000 typ host"))
    #expect(NetworkLeakTest.matchesExit(mdns, exit: "192.0.2.1") == nil)
    #expect(NetworkLeakTest.candidate("candidate:a 1 udp 100 not-an-address 5000 typ srflx") == nil)
    #expect(NetworkLeakTest.candidate("candidate:a 1 udp 100 999.0.0.1 5000 typ srflx") == nil)
    #expect(NetworkLeakTest.candidate("candidate:a 1 udp 100 192.0.2.1 5000 typ invalid") == nil)
  }

  @Test func keepsAllResolversAndDoesNotTrustConclusion() throws {
    let data = Data(
      """
      [{"ip":"192.0.2.1","type":"ip"},
       {"ip":"192.0.2.2","type":"dns","org":"Example"},
       {"ip":"2001:db8::2","type":"dns","country_name":"Example"},
       {"ip":"192.0.2.2","type":"dns"},
       {"ip":"No leak","type":"conclusion"}]
      """.utf8)
    let result = try NetworkLeakTest.decodeDNS(data)
    #expect(result.exits == ["192.0.2.1"])
    #expect(result.resolvers.map(\.address) == ["192.0.2.2", "2001:db8::2"])
    #expect(throws: (any Error).self) { try NetworkLeakTest.decodeDNS(Data("[]".utf8)) }
    #expect(throws: (any Error).self) {
      try NetworkLeakTest.decodeDNS(Data("<html>error</html>".utf8))
    }
    #expect(throws: (any Error).self) {
      try NetworkLeakTest.decodeDNS(Data(repeating: 32, count: 65_537))
    }
  }

  actor Requests {
    var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
  }

  @Test func probesAreBoundedAndTLSFailureStillReadsObservedResults() async throws {
    let requests = Requests()
    let result = try await NetworkLeakTest.dns { url, _ in
      await requests.append(url)
      if url.path == "/id" { return Data("session123\n".utf8) }
      if url.host?.hasPrefix("ex.") == true { throw URLError(.secureConnectionFailed) }
      return Data("[{\"ip\":\"192.0.2.2\",\"type\":\"dns\"}]".utf8)
    }
    #expect(result.resolvers.count == 1)
    let urls = await requests.urls
    #expect(urls.count == 5)
    #expect(Set(urls.compactMap(\.host)).count == 4)
    #expect(urls.last?.path == "/dnsleak/test/session123")
  }

  @Test func rejectsUntrustedSessionBeforeProbing() async {
    let requests = Requests()
    await #expect(throws: (any Error).self) {
      try await NetworkLeakTest.dns { url, _ in
        await requests.append(url)
        return Data("../../evil.test/".utf8)
      }
    }
    #expect(await requests.urls.count == 1)
  }

  @Test func cancellationDoesNotContinueProbesOrReadResults() async {
    let requests = Requests()
    let task = Task {
      try await NetworkLeakTest.dns { url, _ in
        await requests.append(url)
        if url.path == "/id" { return Data("session123".utf8) }
        try await Task.sleep(for: .seconds(30))
        return Data()
      }
    }
    while await requests.urls.count < 2 { await Task.yield() }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(await requests.urls.count == 2)
  }
}
