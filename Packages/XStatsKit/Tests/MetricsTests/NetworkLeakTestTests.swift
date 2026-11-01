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

  @Test func acceptsUnavailableDNSMetadataWithoutDiscardingResolvers() throws {
    let data = Data(
      """
      [{"ip":"192.0.2.1","type":"ip","country_name":false,"asn":false},
       {"ip":"192.0.2.2","type":"dns","country_name":false,"asn":false},
       {"ip":"192.0.2.3","type":"dns","country_name":null,"asn":"AS64500"},
       {"ip":"192.0.2.4","type":"dns","country_name":"Example","org":"Operator","asn":false},
       {"ip":"No leak","type":"conclusion","country_name":false,"asn":false}]
      """.utf8)
    let result = try NetworkLeakTest.decodeDNS(data)
    #expect(result.exits == ["192.0.2.1"])
    #expect(result.resolvers.map(\.address) == ["192.0.2.2", "192.0.2.3", "192.0.2.4"])
    #expect(result.resolvers.map(\.country) == ["", "", "Example"])
    #expect(result.resolvers.map(\.organization) == ["", "AS64500", "Operator"])
  }

  @Test func unavailableConclusionMetadataDoesNotInvalidateValidDNSRecord() throws {
    let data = Data(
      """
      [{"ip":"192.0.2.2","type":"dns","country_name":"Example","asn":"AS64500"},
       {"ip":"No leak","type":"conclusion","country_name":false,"asn":false}]
      """.utf8)
    let result = try NetworkLeakTest.decodeDNS(data)
    #expect(result.resolvers.map(\.address) == ["192.0.2.2"])
    #expect(result.resolvers.first?.organization == "AS64500")
  }

  @Test func optionalMetadataDoesNotRelaxRequiredDNSFields() {
    for json in [
      "[{\"ip\":false,\"type\":\"dns\",\"country_name\":false}]",
      "[{\"ip\":\"192.0.2.2\",\"type\":false,\"asn\":false}]",
      "[{\"ip\":\"192.0.2.2\",\"asn\":false}]",
      "[{\"ip\":\"not-an-address\",\"type\":\"dns\",\"asn\":false}]",
    ] {
      #expect(throws: NetworkLeakTest.Failure.self) {
        try NetworkLeakTest.decodeDNS(Data(json.utf8))
      }
    }
  }

  actor Requests {
    var urls: [URL] = []
    var commands: [String] = []
    var hosts: [String] = []
    var registrations: [Bool] = []
    var active = 0
    var peak = 0
    func record(_ request: URLRequest) {
      if let url = request.url { urls.append(url) }
      if let body = request.httpBody { commands.append(String(decoding: body, as: UTF8.self)) }
    }
    func register(_ ipv6: Bool) { registrations.append(ipv6) }
    func begin(_ host: String) {
      hosts.append(host)
      active += 1
      peak = max(peak, active)
    }
    func end() { active -= 1 }
  }

  private static let runData = Data(
    """
    {"kind":"test","run_id":"session123","cmd":"dnsleaktest","url":"/dnsleak/test/session123"}
    """.utf8)

  @Test func successfulRunReturnsObservedExitsAndResolversAfterAllProbes() async throws {
    let requests = Requests()
    let result = try await NetworkLeakTest.dns(
      request: { request in
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let expected = [
          "ajax=1&start=1&url=/dnsleak",
          "ajax=1&exec=1&url=/dnsleak/test/session123",
          "ajax=1&checkrun=1&url=/dnsleak/test/session123&summary=1",
          "",
        ]
        let step = await requests.urls.count
        try #require(step < expected.count)
        #expect(body == expected[step])
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "bash.ws")
        #expect(request.timeoutInterval == 6)
        #expect(request.httpMethod == (step == 3 ? "GET" : "POST"))
        await requests.record(request)
        switch step {
        case 0:
          #expect(await requests.registrations.isEmpty)
          return Self.runData
        case 1:
          #expect(await requests.registrations == [false, true])
          #expect(await requests.hosts.isEmpty)
          return Data("{\"started\":1}".utf8)
        case 2:
          #expect(await requests.hosts.count == 30)
          #expect(await requests.active == 0)
          // 未请求摘要时，真实服务会附带超过响应上限的完整 HTML。
          if !body.contains("&summary=1") {
            return Data(
              "{\"done\":1,\"format\":\"html\",\"result\":\"\(String(repeating: "x", count: 120_000))\"}"
                .utf8)
          }
          return Data("{\"done\":1,\"summary\":{}}".utf8)
        default:
          #expect(request.url?.absoluteString == "https://bash.ws/dnsleak/test/session123?json=2")
          return Data(
            """
            [{"ip":"192.0.2.1","type":"ip"},
             {"ip":"192.0.2.53","type":"dns","country_name":"Example","org":"Resolver A"},
             {"ip":"2001:db8::53","type":"dns","country_name":false,"asn":"AS64500"},
             {"ip":"192.0.2.53","type":"dns"},
             {"ip":"No leak","type":"conclusion"}]
            """.utf8)
        }
      },
      register: { url, ipv6 in
        #expect(await requests.commands == ["ajax=1&start=1&url=/dnsleak"])
        #expect(
          url.absoluteString
            == "https://\(ipv6 ? "ipv6" : "ipv4").bash.ws/myip/test/session123")
        await requests.register(ipv6)
      },
      resolve: { host in
        #expect(await requests.commands.last == "ajax=1&exec=1&url=/dnsleak/test/session123")
        await requests.begin(host)
        await requests.end()
      })
    #expect(await requests.urls.count == 4)
    #expect(await Set(requests.hosts).count == 30)
    #expect(result.exits == ["192.0.2.1"])
    #expect(result.resolvers.map(\.address) == ["192.0.2.53", "2001:db8::53"])
    #expect(result.resolvers.map(\.organization) == ["Resolver A", "AS64500"])
    #expect(result.resolvers.map(\.country) == ["Example", ""])
  }

  @Test(arguments: 0..<4)
  func requestTimeoutStopsAtTheFailedPhase(_ failedStep: Int) async {
    let requests = Requests()
    do {
      _ = try await NetworkLeakTest.dns(
        request: { request in
          let step = await requests.urls.count
          await requests.record(request)
          if step == failedStep { throw URLError(.timedOut) }
          switch step {
          case 0: return Self.runData
          case 1: return Data("{\"started\":1}".utf8)
          case 2: return Data("{\"done\":1}".utf8)
          default:
            Issue.record("Request continued past the failed phase")
            return Data()
          }
        },
        register: { _, ipv6 in await requests.register(ipv6) },
        resolve: { host in
          await requests.begin(host)
          await requests.end()
        })
      Issue.record("Expected request timeout")
    } catch {
      #expect((error as? URLError)?.code == .timedOut)
    }
    #expect(await requests.urls.count == failedStep + 1)
    #expect(await requests.registrations.count == (failedStep == 0 ? 0 : 2))
    #expect(await requests.hosts.count == (failedStep < 2 ? 0 : 30))
    #expect(await requests.active == 0)
  }

  @Test(arguments: ["{}", "{\"done\":2}", "{\"error\":\"Unavailable\"}", "<html>Error</html>"])
  func invalidProgressDoesNotFetchResults(_ json: String) async {
    let requests = Requests()
    await #expect(throws: NetworkLeakTest.Failure.invalidResponse) {
      try await NetworkLeakTest.dns(
        request: { request in
          let step = await requests.urls.count
          await requests.record(request)
          switch step {
          case 0: return Self.runData
          case 1: return Data("{\"started\":1}".utf8)
          default: return Data(json.utf8)
          }
        },
        register: { _, _ in }, resolve: { _ in })
    }
    #expect(await requests.urls.count == 3)
    #expect(await requests.urls.allSatisfy { $0.query == nil })
  }

  @Test func webProtocolUsesSystemResolutionAndBoundedProbes() async throws {
    let requests = Requests()
    let result = try await NetworkLeakTest.dns(
      request: { request in
        await requests.record(request)
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if request.url?.path == "/dnsleak" {
          #expect(request.httpMethod == "POST")
          #expect(
            request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded"
          )
          if body.contains("&start=1&") { return Self.runData }
          if body.contains("&exec=1&") {
            #expect(await requests.registrations.count == 2)
            #expect(await requests.hosts.isEmpty)
            return Data("{\"started\":1}".utf8)
          }
          #expect(body == "ajax=1&checkrun=1&url=/dnsleak/test/session123&summary=1")
          #expect(await requests.active == 0)
          #expect(await requests.hosts.count == 30)
          return Data("{\"done\":1,\"summary\":{\"message\":\"Ignored\",\"rate\":-1}}".utf8)
        }
        #expect(await requests.active == 0)
        #expect(await requests.hosts.count == 30)
        return Data("[{\"ip\":\"192.0.2.2\",\"type\":\"dns\"}]".utf8)
      },
      register: { url, ipv6 in
        #expect(url.host == (ipv6 ? "ipv6.bash.ws" : "ipv4.bash.ws"))
        #expect(url.path == "/myip/test/session123")
        await requests.register(ipv6)
        // 单个地址族不可用不影响 DNS 结果。
        throw URLError(.cannotConnectToHost)
      },
      resolve: { host in
        #expect(await requests.registrations.count == 2)
        #expect(await requests.commands.contains("ajax=1&exec=1&url=/dnsleak/test/session123"))
        await requests.begin(host)
        try await Task.sleep(for: .milliseconds(1))
        await requests.end()
        // 即使域名没有可连接的地址，权威服务器仍可能已经观察到查询。
        throw URLError(.cannotFindHost)
      })
    #expect(result.resolvers.count == 1)
    let urls = await requests.urls
    #expect(urls.count == 4)
    #expect(await requests.commands.first == "ajax=1&start=1&url=/dnsleak")
    #expect(urls.last?.path == "/dnsleak/test/session123")
    #expect(urls.last?.query == "json=2")
    #expect(await Set(requests.hosts) == Set((1...30).map { "\($0).session123.bash.ws" }))
    #expect(await requests.peak <= 2)
    #expect(await Set(requests.registrations) == [false, true])
  }

  @Test(arguments: [
    "../../evil.test/", "<html>not a session</html>", "", String(repeating: "a", count: 64),
    "session123&exec=1",
  ])
  func rejectsUntrustedSessionBeforeProbing(_ token: String) async {
    let requests = Requests()
    await #expect(throws: (any Error).self) {
      try await NetworkLeakTest.dns(
        request: { request in
          await requests.record(request)
          return try JSONSerialization.data(withJSONObject: [
            "kind": "test", "cmd": "dnsleaktest", "run_id": token, "url": "/dnsleak/test/\(token)",
          ])
        },
        register: { _, _ in Issue.record("Invalid session must not register addresses") },
        resolve: { _ in Issue.record("Invalid session must not trigger DNS") })
    }
    #expect(await requests.urls.count == 1)
  }

  @Test(arguments: [
    "<html>not JSON</html>",
    "{\"kind\":\"test\",\"run_id\":\"session123\",\"cmd\":\"dnsleaktest\",\"url\":\"https://evil.test/\"}",
    "{\"kind\":\"command\",\"run_id\":\"session123\",\"cmd\":\"ping\",\"url\":\"/dnsleak/test/session123\"}",
    "{\"error\":\"Unavailable\"}",
  ])
  func rejectsMalformedOrRedirectedRuns(_ json: String) async {
    await #expect(throws: NetworkLeakTest.Failure.self) {
      try await NetworkLeakTest.dns(
        request: { _ in Data(json.utf8) },
        register: { _, _ in Issue.record("Invalid run must not register addresses") },
        resolve: { _ in Issue.record("Invalid run must not trigger DNS") })
    }
  }

  @Test(arguments: ["{\"started\":0}", "{\"error\":\"Unable to start\"}", "{}"])
  func failedExecutionDoesNotTriggerDNS(_ json: String) async {
    let requests = Requests()
    await #expect(throws: NetworkLeakTest.Failure.self) {
      try await NetworkLeakTest.dns(
        request: { request in
          await requests.record(request)
          return request.httpBody == Data("ajax=1&start=1&url=/dnsleak".utf8)
            ? Self.runData : Data(json.utf8)
        },
        register: { _, _ in },
        resolve: { _ in Issue.record("Failed execution must not trigger DNS") })
    }
    #expect(await requests.urls.count == 2)
  }

  @Test(arguments: [true, false])
  func waitsForResultsWithBoundedPolling(_ completes: Bool) async throws {
    let requests = Requests()
    do {
      let result = try await NetworkLeakTest.dns(
        request: { request in
          await requests.record(request)
          let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
          if body.contains("&start=1&") { return Self.runData }
          if body.contains("&exec=1&") { return Data("{\"started\":1}".utf8) }
          if body.contains("&checkrun=1&") {
            let polls = await requests.commands.filter { $0.contains("&checkrun=1&") }.count
            return Data((completes && polls == 2 ? "{\"done\":1}" : "{\"done\":0}").utf8)
          }
          return Data("[{\"ip\":\"192.0.2.53\",\"type\":\"dns\"}]".utf8)
        },
        register: { _, _ in }, resolve: { _ in })
      #expect(completes)
      #expect(result.resolvers.map(\.address) == ["192.0.2.53"])
    } catch {
      #expect(!completes)
      #expect(error as? NetworkLeakTest.Failure == .unavailable)
    }
    let polls = await requests.commands.filter { $0.contains("&checkrun=1&") }.count
    #expect(polls == (completes ? 2 : 4))
    #expect(await requests.urls.contains { $0.query == "json=2" } == completes)
  }

  @Test func cancellationDuringPollingDoesNotFetchResults() async {
    let requests = Requests()
    let task = Task {
      try await NetworkLeakTest.dns(
        request: { request in
          await requests.record(request)
          let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
          if body.contains("&start=1&") { return Self.runData }
          if body.contains("&exec=1&") { return Data("{\"started\":1}".utf8) }
          return Data("{\"done\":0}".utf8)
        },
        register: { _, _ in }, resolve: { _ in })
    }
    while await requests.urls.count < 3 { await Task.yield() }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(await requests.urls.count == 3)
  }

  @Test func cancellationDoesNotContinueProbesOrReadResults() async {
    let requests = Requests()
    let task = Task {
      try await NetworkLeakTest.dns(
        request: { request in
          await requests.record(request)
          return request.httpBody == Data("ajax=1&start=1&url=/dnsleak".utf8)
            ? Self.runData : Data("{\"started\":1}".utf8)
        },
        register: { _, _ in },
        resolve: { host in
          await requests.begin(host)
          try await Task.sleep(for: .seconds(30))
        })
    }
    while await requests.hosts.count < 2 { await Task.yield() }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(await requests.urls.count == 2)
    #expect(await requests.hosts.count == 2)
  }

  @Test func cancellationDuringRegistrationDoesNotTriggerDNS() async {
    let requests = Requests()
    let task = Task {
      try await NetworkLeakTest.dns(
        request: { request in
          await requests.record(request)
          return Self.runData
        },
        register: { _, ipv6 in
          await requests.register(ipv6)
          try await Task.sleep(for: .seconds(30))
        },
        resolve: { _ in Issue.record("Cancelled registration must not trigger DNS") })
    }
    while await requests.registrations.isEmpty { await Task.yield() }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(await requests.urls.count == 1)
  }

  @Test func nativeQueryReleasesAfterLocalResolutionTimeoutAndCancellation() async {
    for (cancel, timeout) in [(false, 30.0), (false, 0.0), (true, 30.0)] {
      let started = ContinuousClock.now
      let task = Task {
        var query: DNSLeakQuery? = DNSLeakQuery(host: "localhost.", timeout: timeout)
        weak var released = query
        if cancel {
          withUnsafeCurrentTask { $0?.cancel() }
        }
        await query?.run()
        query = nil
        // continuation 恢复时 C 回调可能尚未退栈，等待其释放最后一个临时引用。
        let deadline = ContinuousClock.now + .seconds(1)
        while released != nil, ContinuousClock.now < deadline { await Task.yield() }
        return released == nil
      }
      #expect(await task.value)
      #expect(started.duration(to: .now) < .seconds(3))
    }
  }
}
