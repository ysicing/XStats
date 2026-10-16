// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct AppStoreUpdatesTests {
  @Test func onlyCompatibleMacVersionsProduceUpdates() throws {
    let data = Data(
      #"{"results":[{"kind":"mac-software","bundleId":"test.mac","version":"1.10","minimumOsVersion":"14.0","trackId":123},{"kind":"software","bundleId":"test.phone","version":"99","minimumOsVersion":"14"},{"kind":"mac-software","bundleId":"test.future","version":"2","minimumOsVersion":"27"}]}"#
        .utf8)
    let entries = try AppStoreUpdates.parse(data, usingStoreIDs: false)
    let current = AppStoreUpdates.Candidate(
      bundleIdentifier: "test.mac", version: "1.9", storeID: nil)
    #expect(entries["test.mac"]?.update(for: current, systemVersion: "14.0")?.version == "1.10")
    #expect(
      entries["test.mac"]?.storeURL.absoluteString == "macappstore://itunes.apple.com/app/id123")
    #expect(entries["test.phone"] == nil)
    #expect(
      entries["test.future"]?.update(
        for: .init(bundleIdentifier: "test.future", version: "1", storeID: nil), systemVersion: "26"
      ) == nil)
    #expect(
      entries["test.mac"]?.update(
        for: .init(bundleIdentifier: "test.mac", version: "1.10.0", storeID: nil),
        systemVersion: "14") == nil)
    #expect(
      entries["test.mac"]?.update(
        for: .init(bundleIdentifier: "other", version: "1", storeID: nil), systemVersion: "14")
        == nil)
  }

  @Test func platformLookupRejectsMobileOffersAndMalformedVersions() throws {
    let data = Data(
      #"{"results":{"123":{"bundleId":"test.mac","deviceFamilies":["mac"],"minimumOSVersion":"14","offers":[{"version":{"display":"99"},"assets":[{"flavor":"software"}]},{"version":{"display":"2.0"},"assets":[{"flavor":"macSoftware"}]}]}}}"#
        .utf8)
    let entries = try AppStoreUpdates.parse(data, usingStoreIDs: true)
    #expect(entries["test.mac"]?.version == "2.0")
    #expect(entries["test.mac"]?.storeID == "123")
    #expect(!AppStoreUpdates.isNewer("1.0", than: "1.0.0"))
    #expect(!AppStoreUpdates.isNewer("2 beta", than: "1"))
    #expect(AppStoreUpdates.isNewer("2.10", than: "2.9"))
  }

  @Test func requestsBatchAndFallbackWithoutLosingPartialResults() async throws {
    let candidates = (0..<21).map {
      AppStoreUpdates.Candidate(
        bundleIdentifier: "test.\($0)", version: "1", storeID: "\($0 + 100)")
    }
    let response = try await AppStoreUpdates.check(candidates, country: "SG") { url in
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      if url.host == "uclient-api.itunes.apple.com" { return Data(#"{"results":{}}"#.utf8) }
      let ids = try #require(query.first { $0.name == "bundleId" }?.value?.split(separator: ","))
      #expect(ids.count <= 20)
      #expect(query.contains { $0.name == "country" && $0.value == "sg" })
      if ids.contains("test.20") { throw URLError(.notConnectedToInternet) }
      return Data(
        #"{"results":[{"kind":"mac-software","bundleId":"test.0","version":"2","minimumOsVersion":"14","trackId":100}]}"#
          .utf8)
    }
    #expect(response.entries["test.0"]?.version == "2")
    #expect(response.entries["test.20"] == nil)
    #expect(response.failedRequests == 1)
  }

  @Test func cancellationStopsBeforeAnotherRequest() async throws {
    let task = Task {
      try await AppStoreUpdates.check(
        [.init(bundleIdentifier: "test.app", version: "1", storeID: "123")], country: "US"
      ) { _ in
        throw CancellationError()
      }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
