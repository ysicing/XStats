// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct DashboardTests {
  @Test func defaultAndCustomPortAreMachineLocal() throws {
    let name = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.dashboardEnabled)
    #expect(!settings.dashboardTailscaleEnabled)
    #expect(settings.dashboardPort == 3261)
    settings.dashboardEnabled = true
    settings.dashboardTailscaleEnabled = true
    settings.dashboardPort = 8330
    let restored = AppSettings(defaults: defaults)
    #expect(restored.dashboardEnabled && restored.dashboardPort == 8330)
    #expect(restored.dashboardTailscaleEnabled)
    defaults.set(65_536, forKey: "dashboardPort")
    #expect(AppSettings(defaults: defaults).dashboardPort == 3261)
    for blocked in [22, 4190, 6000, 10080] {
      defaults.set(blocked, forKey: "dashboardPort")
      #expect(AppSettings(defaults: defaults).dashboardPort == 3261)
    }
    defaults.set(65535, forKey: "dashboardPort")
    #expect(AppSettings(defaults: defaults).dashboardPort == 65535)
  }

  @Test func parserAcceptsSplitBodiesAndRejectsAmbiguousFraming() {
    var parser = DashboardHTTPParser()
    if case .incomplete = parser.append(
      Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:3261\r\nContent-Length: 4\r\n\r\nab".utf8))
    {
    } else {
      Issue.record("Expected the remaining body")
    }
    if case .request(let request) = parser.append(Data("cd".utf8)) {
      #expect(request.body == Data("abcd".utf8))
    } else {
      Issue.record("Expected a complete request")
    }
    for (header, status) in [
      ("Content-Length: 2\r\ncontent-length: 3", 400),
      ("Transfer-Encoding: chunked\r\nContent-Length: 3", 400),
      ("Content-Length: 65536", 413),
      ("Content-Length: x", 400),
    ] {
      parser = DashboardHTTPParser()
      if case .rejected(let actual) = parser.append(
        Data("POST /mcp HTTP/1.1\r\nHost: localhost:3261\r\n\(header)\r\n\r\n".utf8))
      {
        #expect(actual == status)
      } else {
        Issue.record("Expected to reject \(header)")
      }
    }
  }

  @Test func lanAndCrossOriginRequestsCannotReachMCP() async throws {
    let settings = try testSettings()
    let store = MetricsStore(readBattery: false)
    let dashboard = DashboardController()
    let localMCP = ["host": "127.0.0.1:3261", "content-type": "application/json"]
    let forged = DashboardHTTPRequest(method: "POST", path: "/mcp", headers: localMCP)
    #expect(
      await dashboard.respond(forged, peer: .local, port: 3261, settings: settings, store: store)
        .status == 403)
    let externalOrigin = DashboardHTTPRequest(
      method: "POST", path: "/mcp",
      headers: localMCP.merging(["origin": "https://example.com"]) { current, _ in current })
    #expect(
      await dashboard.respond(
        externalOrigin, peer: .loopback, port: 3261, settings: settings, store: store
      ).status == 403)
    let externalHost = DashboardHTTPRequest(
      method: "GET", path: "/api/snapshot", headers: ["host": "example.com:3261"])
    #expect(
      await dashboard.respond(
        externalHost, peer: .loopback, port: 3261, settings: settings, store: store
      ).status == 403)
    #expect(!dashboard.hasViewerDemand)
    #expect(DashboardPeer(.ipv4(IPv4Address("192.168.1.2")!)) == .local)
    #expect(DashboardPeer(.ipv4(IPv4Address("1.1.1.1")!)) == nil)
    #expect(DashboardPeer(.ipv6(IPv6Address("::ffff:127.0.0.1")!)) == .loopback)
  }

  @Test func advertisedAddressesTrackTheCurrentLANInterfaces() {
    let vpn = LocalNetworkInterface(bsdName: "utun3", kind: .tunnel, ipv4: ["10.8.0.2"])
    let wifi = LocalNetworkInterface(
      bsdName: "en0", kind: .wifi, ipv4: ["192.168.2.4"], ipv6: ["fd00::4"],
      linkLocal: ["fe80::4%en0"])
    let wired = LocalNetworkInterface(bsdName: "en5", kind: .ethernet, ipv4: ["169.254.2.4"])
    #expect(DashboardSettings.webAddresses(for: [vpn, wifi]) == ["192.168.2.4", "fd00::4"])
    #expect(DashboardSettings.webAddresses(for: [vpn, wired]) == ["169.254.2.4"])
    #expect(DashboardSettings.webAddresses(for: [vpn]).isEmpty)
  }

  @Test func tailscaleMCPRequiresOptInAndMatchingListenerAddress() async throws {
    let settings = try testSettings()
    let store = MetricsStore(readBattery: false)
    let dashboard = DashboardController()
    let ipv4 = NWEndpoint.Host("100.65.2.7")
    let ipv6 = NWEndpoint.Host("fd7a:115c:a1e0::7")
    let request = DashboardHTTPRequest(
      method: "POST", path: "/mcp",
      headers: ["host": "100.65.2.7:3261", "content-type": "application/json"],
      body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
    #expect(
      await dashboard.respond(
        request, peer: .tailscale(ipv4), port: 3261, settings: settings, store: store
      ).status == 403)
    settings.dashboardTailscaleEnabled = true
    #expect(
      await dashboard.respond(
        request, peer: .tailscale(ipv4), port: 3261, settings: settings, store: store
      ).status == 200)
    #expect(
      await dashboard.respond(
        request, peer: .local, port: 3261, settings: settings, store: store
      ).status == 403)
    for (host, expected) in [
      ("[fd7a:115c:a1e0::7]:3261", 200),
      ("[fd7a:115c:a1e0::8]:3261", 403),
      ("127.0.0.1:3261", 403),
      ("example.com:3261", 403),
    ] {
      let routedRequest = DashboardHTTPRequest(
        method: request.method, path: request.path,
        headers: ["host": host, "content-type": "application/json"], body: request.body)
      #expect(
        await dashboard.respond(
          routedRequest, peer: .tailscale(ipv6), port: 3261, settings: settings, store: store
        ).status == expected)
    }
    #expect(DashboardPeer.isTailscaleAddress(ipv4))
    #expect(DashboardPeer.isTailscaleAddress(ipv6))
    #expect(DashboardPeer.isTailscaleAddress(NWEndpoint.Host("::ffff:100.64.0.1")))
    for address in ["100.63.0.1", "100.128.0.1", "10.1.2.3", "fd00::7", "127.0.0.1"] {
      #expect(!DashboardPeer.isTailscaleAddress(NWEndpoint.Host(address)))
    }
  }

  @Test func dashboardLanguagesAreReadOnlyAndAvailableWithoutSampling() async throws {
    let settings = try testSettings()
    let store = MetricsStore(readBattery: false)
    let dashboard = DashboardController()
    var keys: Set<String>?
    for code in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "es", "fr", "ar"] {
      let request = DashboardHTTPRequest(
        method: "GET", path: "/dashboard/locale/\(code)", headers: ["host": "192.168.1.2:3261"])
      let response = await dashboard.respond(
        request, peer: .local, port: 3261, settings: settings, store: store)
      #expect(response.status == 200)
      let labels = try #require(json(response) as? [String: String])
      if let keys { #expect(Set(labels.keys) == keys) } else { keys = Set(labels.keys) }
      #expect(labels.values.allSatisfy { !$0.isEmpty })
      if code == "ar" {
        #expect(labels["title"] == "لوحة المراقبة")
        #expect(labels["followApp"] == "اتباع لغة XStats")
      }
    }
    let unknown = DashboardHTTPRequest(
      method: "GET", path: "/dashboard/locale/unknown", headers: ["host": "192.168.1.2:3261"])
    let response = await dashboard.respond(
      unknown, peer: .local, port: 3261, settings: settings, store: store)
    #expect(response.status == 404)
    #expect(!dashboard.hasViewerDemand)
  }

  @Test func calendarSummaryShowsSpecialDaysBeforeOrdinaryWeekdaysAndWeekends() async throws {
    let settings = try testSettings()
    let store = MetricsStore(readBattery: false)
    let dashboard = DashboardController()
    for (date, expected, isExact) in [
      ("2026-09-25", "农历八月十五 · 中秋节 · 放假", true),
      ("2026-09-20", "补班", false),
      ("2026-09-23", "秋分 · 周三", false),
      ("2026-09-24", "周四", false),
      ("2026-04-12", "周末", false),
      ("2099-01-03", "周六", false),
    ] {
      let request = DashboardHTTPRequest(
        method: "GET", path: "/dashboard/calendar/zh-Hans/\(date)",
        headers: ["host": "192.168.1.2:3261"])
      let response = await dashboard.respond(
        request, peer: .local, port: 3261, settings: settings, store: store)
      #expect(response.status == 200)
      let summary = try JSONDecoder().decode(String.self, from: response.body)
      #expect(isExact ? summary == expected : summary.hasSuffix(" · " + expected))
    }
    let localized = try #require(
      DashboardCalendar.summary(for: "2026-09-25", language: .english))
    #expect(localized.hasPrefix("Lunar "))
    #expect(localized.hasSuffix(" · Mid-Autumn Festival · Holiday"))
    let invalid = DashboardHTTPRequest(
      method: "GET", path: "/dashboard/calendar/zh-Hans/2026-02-30",
      headers: ["host": "192.168.1.2:3261"])
    let response = await dashboard.respond(
      invalid, peer: .local, port: 3261, settings: settings, store: store)
    #expect(response.status == 404)
    #expect(!dashboard.hasViewerDemand)
  }

  @Test func webAndMCPShareReadingsAndRespectPauseAndMonitoringSwitches() async throws {
    let settings = try testSettings()
    settings.setModuleEnabled(.cpu, true)
    settings.setModuleEnabled(.disk, true)
    settings.setModuleEnabled(.network, true)
    let store = MetricsStore(readBattery: false)
    let dashboard = DashboardController()
    defer { dashboard.stop() }
    let web = DashboardHTTPRequest(
      method: "GET", path: "/api/snapshot", headers: ["host": "192.168.1.2:3261"])
    let initial = await dashboard.respond(
      web, peer: .local, port: 3261, settings: settings, store: store)
    #expect(initial.appLanguage == settings.language.languageCode)
    #expect(
      String(decoding: initial.wireData, as: UTF8.self)
        .contains("X-XStats-Language: \(settings.language.languageCode)\r\n"))
    #expect(try json(initial)["status"] as? String == "sampling")
    #expect(dashboard.hasViewerDemand)

    var owned = ProcessUsage(
      pid: 5, name: "example", executablePath: "/Users/private/Example", appBundlePath: nil,
      cpu: 0.3, memory: 12_000)
    owned.uid = getuid()
    var foreign = owned
    foreign.isOwned = false
    var sample = MetricsSnapshot()
    sample.disk = DiskUsage(volumeName: "Private Volume", total: 100, available: 45)
    sample.processes = [foreign, owned]
    sample.network = NetworkRate(
      interfaceName: "en0", downloadBytesPerSecond: 100, uploadBytesPerSecond: 50,
      totalDownloaded: 100, totalUploaded: 50)
    sample.networkInterface = NetworkInterfaceInfo(
      bsdName: "en0", displayName: "Wi-Fi", ipv4: "192.168.1.42")
    store.apply(sample)
    dashboard.record(sample)
    let reading = await dashboard.respond(
      web, peer: .local, port: 3261, settings: settings, store: store)
    let snapshot = try json(reading)
    #expect(snapshot["status"] as? String == "live")
    #expect((snapshot["disk"] as? [String: Int])?["usedBytes"] == 55)
    #expect((snapshot["processes"] as? [[String: Any]])?.count == 1)
    let network = try #require(snapshot["network"] as? [String: Any])
    #expect(network["interfaceName"] as? String == "en0")
    #expect(network["interfaceDisplayName"] as? String == "Wi-Fi")
    #expect(network["ipv4"] as? String == "192.168.1.42")
    #expect(!String(decoding: reading.body, as: UTF8.self).contains("Private Volume"))
    #expect(!String(decoding: reading.body, as: UTF8.self).contains("/Users/private"))

    let rpc = DashboardHTTPRequest(
      method: "POST", path: "/mcp",
      headers: ["host": "127.0.0.1:3261", "content-type": "application/json"],
      body: Data(
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_monitoring_snapshot"}}"#
          .utf8))
    let call = await dashboard.respond(
      rpc, peer: .loopback, port: 3261, settings: settings, store: store)
    let result = try #require(json(call)["result"] as? [String: Any])
    let structured = try #require(result["structuredContent"] as? NSDictionary)
    #expect(structured == snapshot as NSDictionary)

    sample.network?.interfaceName = "en1"
    store.apply(sample)
    dashboard.record(sample)
    let switched = await dashboard.respond(
      web, peer: .local, port: 3261, settings: settings, store: store)
    let newInterface = try #require(json(switched)["network"] as? [String: Any])
    #expect(newInterface["interfaceName"] as? String == "en1")
    #expect(newInterface["interfaceDisplayName"] == nil)
    #expect(newInterface["ipv4"] == nil)

    settings.setModuleEnabled(.cpu, false)
    settings.setModuleEnabled(.disk, false)
    settings.setModuleEnabled(.network, false)
    let disabled = await dashboard.respond(
      web, peer: .local, port: 3261, settings: settings, store: store)
    #expect(try json(disabled)["processes"] == nil)
    #expect(try json(disabled)["disk"] == nil)
    #expect(try json(disabled)["network"] == nil)
    dashboard.setPaused(true)
    let paused = await dashboard.respond(
      web, peer: .local, port: 3261, settings: settings, store: store)
    #expect(try json(paused)["status"] as? String == "paused")
    #expect(!dashboard.hasViewerDemand)
  }

  @Test(.timeLimit(.minutes(1))) func HTTPListenerServesMCPHandshakeAndReleasesPort() async throws {
    let settings = try testSettings()
    let store = MetricsStore(readBattery: false)
    let dashboard = DashboardController()
    let server = try DashboardHTTPServer(port: 0)
    defer { server.stop() }
    var ready = false
    server.start { state in
      if case .ready = state { ready = true }
    } handle: { request, peer in
      guard let port = server.boundPort else { return DashboardHTTPResponse(status: 500) }
      return await dashboard.respond(
        request, peer: peer, port: port, settings: settings, store: store)
    }
    for _ in 0..<50 where !ready { try await Task.sleep(for: .milliseconds(20)) }
    try #require(ready)
    let port = try #require(server.boundPort)
    let address = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: address)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = Data(
      #"{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-11-25"}}"#
        .utf8)
    let (body, response) = try await session.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let initialize = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((initialize["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
    request.httpBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
    let (_, notification) = try await session.data(for: request)
    #expect((notification as? HTTPURLResponse)?.statusCode == 202)
    request.httpBody = Data(#"{"jsonrpc":"2.0","method":"tools/list","id":2}"#.utf8)
    let (toolBody, _) = try await session.data(for: request)
    let tools = try #require(JSONSerialization.jsonObject(with: toolBody) as? [String: Any])
    let result = try #require(tools["result"] as? [String: Any])
    #expect(
      (result["tools"] as? [[String: Any]])?.first?["name"] as? String == "get_monitoring_snapshot")
    #expect(!dashboard.hasViewerDemand)
    server.stop()
    await #expect(throws: URLError.self) { try await session.data(for: request) }
  }

  @Test(.timeLimit(.minutes(1))) func changingPortsReplacesTheActiveListener() async throws {
    let settings = try testSettings()
    let store = MetricsStore(readBattery: false)
    let dashboard = DashboardController()
    defer { dashboard.stop() }
    let first = try DashboardHTTPServer(port: 0)
    let second = try DashboardHTTPServer(port: 0)
    defer {
      first.stop()
      second.stop()
    }
    first.start { _ in
    } handle: { _, _ in
      DashboardHTTPResponse(status: 200)
    }
    second.start { _ in
    } handle: { _, _ in
      DashboardHTTPResponse(status: 200)
    }
    for _ in 0..<50 where first.boundPort == nil || second.boundPort == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    let firstPort = try #require(first.boundPort)
    let secondPort = try #require(second.boundPort)
    let firstAddress = try #require(URL(string: "http://127.0.0.1:\(firstPort)/"))
    let secondAddress = try #require(URL(string: "http://127.0.0.1:\(secondPort)/"))
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }

    first.stop()
    settings.dashboardEnabled = true
    settings.dashboardPort = firstPort
    dashboard.configure(port: firstPort, settings: settings, store: store)
    for _ in 0..<50 where dashboard.status == .starting {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(dashboard.status == .listening)
    let (_, firstResponse) = try await session.data(from: firstAddress)
    #expect((firstResponse as? HTTPURLResponse)?.statusCode == 200)

    second.stop()
    settings.dashboardPort = secondPort
    dashboard.configure(port: secondPort, settings: settings, store: store)
    for _ in 0..<50 where dashboard.status == .starting {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(dashboard.status == .listening)
    let (_, secondResponse) = try await session.data(from: secondAddress)
    #expect((secondResponse as? HTTPURLResponse)?.statusCode == 200)
    await #expect(throws: URLError.self) { try await session.data(from: firstAddress) }
    settings.dashboardEnabled = false
    dashboard.configure(port: nil, settings: settings, store: store)
    #expect(dashboard.status == .off)
    await #expect(throws: URLError.self) { try await session.data(from: secondAddress) }
  }

  private func testSettings() throws -> AppSettings {
    AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
  }

  @Test(.timeLimit(.minutes(1))) func remoteViewAddsAndReleasesOnlySupportedSamplingDemand()
    async throws
  {
    let settings = try testSettings()
    settings.dashboardEnabled = true
    settings.refreshSeconds = 5
    let model = AppModel(settings: settings, historyURL: nil)
    defer { model.dashboard.stop() }
    let baseline = model.demand
    #expect(baseline.interval == .seconds(5))
    let page = DashboardHTTPRequest(
      method: "GET", path: "/", headers: ["host": "127.0.0.1:3261"])
    let html = await model.dashboard.respond(
      page, peer: .loopback, port: 3261, settings: settings, store: model.store)
    #expect(html.status == 200)
    #expect(model.demand == baseline)

    let api = DashboardHTTPRequest(
      method: "GET", path: "/api/snapshot", headers: ["host": "127.0.0.1:3261"])
    _ = await model.dashboard.respond(
      api, peer: .loopback, port: 3261, settings: settings, store: model.store)
    let viewing = model.demand
    #expect(viewing.interval == .seconds(2))
    #expect(viewing.cpu && viewing.disk && viewing.processes)
    #expect(!viewing.diskDetail && !viewing.systemProcesses && !viewing.networkConnection)
    settings.setModuleEnabled(.cpu, false)
    #expect(!model.demand.cpu && !model.demand.processes)
    settings.setModuleEnabled(.cpu, true)
    for _ in 0..<42 where model.dashboard.hasViewerDemand {
      try await Task.sleep(for: .milliseconds(250))
    }
    #expect(!model.dashboard.hasViewerDemand)
    #expect(model.demand.interval == .seconds(5))
    #expect(model.demand.disk == baseline.disk && model.demand.processes == baseline.processes)
  }

  private func json(_ response: DashboardHTTPResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }
}
