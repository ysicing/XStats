// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics

struct IPGeolocationTests {
  private static let response = Data(
    """
    {"success":true,"ip":"1.2.4.8","country":"China","country_code":"CN",
     "region":"Beijing","city":"Shanghai","capital":"Beijing",
     "connection":{"isp":"Example ISP","domain":"example.cn"}}
    """.utf8)

  actor Requests {
    var count = 0
    func hit() { count += 1 }
  }

  @Test func decodesCityInsteadOfCapitalAndValidatesIdentity() throws {
    let geo = try IPGeolocationLookup.decode(Self.response, address: "1.2.4.8")
    #expect(geo.city == "Shanghai")
    #expect(geo.countryCode == "CN")
    #expect(geo.isp == "Example ISP")
    #expect(geo.domain == "example.cn")
    for data in [
      Data("{\"success\":false,\"message\":\"limit\"}".utf8),
      Self.response, Data(repeating: 32, count: 65_537),
    ] {
      #expect(throws: (any Error).self) {
        try IPGeolocationLookup.decode(data, address: "8.8.8.8")
      }
    }
    let ipv6 = Data(
      "{\"success\":true,\"ip\":\"2001:4860:4860::8888\",\"country_code\":\"US\"}".utf8)
    let sparse = try IPGeolocationLookup.decode(
      ipv6, address: "2001:4860:4860:0:0:0:0:8888")
    #expect(sparse.city.isEmpty)
    #expect(sparse.isp.isEmpty)
  }

  @Test func prefersOrganizationAndFallsBackToISPForMissingOrBlankOrg() throws {
    let isp = "Example International Network Operator with a long ISP name"
    for org in [nil, "", " \n ", " Example Org "] as [String?] {
      var payload = try #require(
        JSONSerialization.jsonObject(with: Self.response) as? [String: Any])
      var connection = ["isp": isp, "domain": "example.cn"]
      if let org { connection["org"] = org }
      payload["connection"] = connection
      let geo = try IPGeolocationLookup.decode(
        JSONSerialization.data(withJSONObject: payload), address: "1.2.4.8")
      let expected = org == " Example Org " ? "Example Org" : isp
      #expect(geo.providerName == expected)
      #expect(geo.isp == isp)
      #expect(geo.domain == "example.cn")
      let restored = try JSONDecoder().decode(IPGeolocation.self, from: JSONEncoder().encode(geo))
      #expect(restored.providerName == expected)
    }
  }

  @Test func existingCacheWithoutOrgStillDecodesAndDisplaysISP() throws {
    let data = Data(
      """
      {"country":"China","countryCode":"CN","region":"Beijing","city":"Beijing",
       "isp":"Existing ISP","domain":"example.cn"}
      """.utf8)
    let geo = try JSONDecoder().decode(IPGeolocation.self, from: data)
    #expect(geo.org == nil)
    #expect(geo.providerName == "Existing ISP")
  }

  @Test func persistsForSevenDaysAndRetainsStaleDataOnFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("geo.json")
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let requests = Requests()
    let initial = IPGeolocationLookup(cacheURL: url, now: { date }) { _ in
      await requests.hit()
      return Self.response
    }
    let value = await initial.lookup("1.2.4.8")
    #expect(value?.city == "Shanghai")
    #expect(await initial.lookup("1.2.4.8") == value)
    #expect(await requests.count == 1)

    let fresh = IPGeolocationLookup(
      cacheURL: url, now: { date.addingTimeInterval(7 * 86_400 - 1) }
    ) { _ in
      await requests.hit()
      throw URLError(.notConnectedToInternet)
    }
    #expect(await fresh.lookup("1.2.4.8") == value)
    #expect(await requests.count == 1)

    let stale = IPGeolocationLookup(
      cacheURL: url, now: { date.addingTimeInterval(7 * 86_400) }
    ) { _ in
      await requests.hit()
      throw URLError(.notConnectedToInternet)
    }
    #expect(await stale.lookup("1.2.4.8") == value)
    #expect(await stale.lookup("1.2.4.8") == value)
    #expect(await requests.count == 3)
    let refreshed = IPGeolocationLookup(
      cacheURL: url, now: { date.addingTimeInterval(8 * 86_400) }
    ) { _ in
      await requests.hit()
      return Data(
        String(decoding: Self.response, as: UTF8.self)
          .replacingOccurrences(of: "Shanghai", with: "Guangzhou").utf8)
    }
    #expect(await refreshed.lookup("1.2.4.8")?.city == "Guangzhou")
    #expect(await refreshed.lookup("1.2.4.8")?.city == "Guangzhou")
    #expect(await requests.count == 4)
  }

  @Test func invalidAddressesAndCancellationDoNotCreateCacheEntries() async throws {
    let requests = Requests()
    let cache = IPGeolocationLookup(cacheURL: nil) { _ in
      await requests.hit()
      try await Task.sleep(for: .seconds(30))
      return Self.response
    }
    for address in ["not-an-ip", "127.0.0.1", "192.168.1.1", "::1", "fe80::1", "fc00::1"] {
      #expect(await cache.lookup(address) == nil)
    }
    #expect(await requests.count == 0)
    let task = Task { await cache.lookup("1.2.4.8") }
    let deadline = ContinuousClock.now + .seconds(2)
    while await requests.count == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await requests.count == 1)
    task.cancel()
    #expect(await task.value == nil)
    let failed = IPGeolocationLookup(cacheURL: nil) { _ in
      throw URLError(.notConnectedToInternet)
    }
    #expect(await failed.lookup("1.2.4.8") == nil)
  }

  @Test func cancellationOfStaleRefreshDoesNotReplaceOrReturnOldData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("geo.json")
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let initial = IPGeolocationLookup(cacheURL: url, now: { date }) { _ in Self.response }
    #expect(await initial.lookup("1.2.4.8") != nil)
    let before = try Data(contentsOf: url)
    let requests = Requests()
    let stale = IPGeolocationLookup(
      cacheURL: url, now: { date.addingTimeInterval(8 * 86_400) }
    ) { _ in
      await requests.hit()
      // 模拟取消后仍返回数据的底层传输。
      try? await Task.sleep(for: .seconds(30))
      return Self.response
    }
    let task = Task { await stale.lookup("1.2.4.8") }
    let deadline = ContinuousClock.now + .seconds(2)
    while await requests.count == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(await requests.count == 1)
    task.cancel()
    #expect(await task.value == nil)
    #expect(try Data(contentsOf: url) == before)
  }

  @Test func cacheBoundsEntriesAndRecoversFromCorruption() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("geo.json")
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let value = try IPGeolocationLookup.decode(Self.response, address: "1.2.4.8")
    let encodedValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    var records: [String: Any] = [:]
    for index in 0...IPGeolocationLookup.capacity {
      records["8.8.\(index / 256).\(index % 256)"] = [
        "value": encodedValue, "fetchedAt": date.timeIntervalSinceReferenceDate - Double(index + 1),
      ]
    }
    try JSONSerialization.data(withJSONObject: records).write(to: url)
    let requests = Requests()
    let cache = IPGeolocationLookup(cacheURL: url, now: { date }) { _ in
      await requests.hit()
      return Self.response
    }
    #expect(await cache.lookup("8.8.0.0") == value)
    #expect(await requests.count == 0)
    #expect(await cache.lookup("1.2.4.8") == value)
    let saved = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(saved.count == IPGeolocationLookup.capacity)
    #expect(saved["8.8.1.0"] == nil)
    for invalid in [Data("{broken".utf8), Data(repeating: 32, count: 2_097_153)] {
      try invalid.write(to: url)
      let recovered = IPGeolocationLookup(cacheURL: url) { _ in Self.response }
      #expect(await recovered.lookup("1.2.4.8") == value)
    }
  }
}
