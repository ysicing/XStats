// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import AIUsage
import Foundation
import Testing

struct MagpieUsageTests {
    @Test func preservesAccountsAndUnknownProviderWindows() throws {
        let data = Data(#"{"object":"list","data":[{"provider":"grok","name":"one","kind":"subscription","windows":[{"name":"7 days","used":32,"remaining":68}]},{"provider":"codex","name":"two","kind":"subscription","last":true,"windows":[]},{"provider":"codex","name":"three","kind":"subscription","error":"failed","windows":[]}]}"#.utf8)
        let quotas = try MagpieClient.decodeQuotas(data)
        #expect(quotas.count == 3)
        #expect(quotas[0].windows[0].remaining == 68)
        #expect(quotas[1].last == true)
        #expect(quotas[1].id != quotas[2].id)
    }

    @Test func overQuotaAccountDoesNotInvalidateOtherAccounts() throws {
        let data = Data(#"{"object":"list","data":[{"provider":"grok","name":"one","kind":"subscription","windows":[{"name":"7 days","used":130,"remaining":0}]}]}"#.utf8)
        let quotas = try MagpieClient.decodeQuotas(data)
        #expect(quotas[0].windows[0].used == 130)
        #expect(quotas[0].windows[0].remaining == 0)
    }

    @Test func accountIdentitySurvivesUnrelatedReordering() throws {
        let first = #"{"provider":"codex","name":"one","kind":"subscription","windows":[]}"#
        let second = #"{"provider":"grok","name":"two","kind":"subscription","windows":[]}"#
        let a = try MagpieClient.decodeQuotas(Data("{\"object\":\"list\",\"data\":[\(first),\(second)]}".utf8))
        let b = try MagpieClient.decodeQuotas(Data("{\"object\":\"list\",\"data\":[\(second),\(first)]}".utf8))
        #expect(a[0].id == b[1].id)
    }

    @Test func usesMagpieTotalsWithoutIncludingCacheTraffic() throws {
        let data = Data(#"{"period":"7d","bucket":"day","input":100,"output":20,"cache_read":500,"cache_write":3,"calls":2,"cost":1.25,"unpriced":0,"models":[],"series":[{"time":"2026-10-11T00:00:00+08:00","input":100,"output":20,"cache_read":500}]}"#.utf8)
        let summary = try MagpieClient.decodeUsage(data, period: .weekly)
        #expect(summary.total == 120)
        #expect(summary.cost == 1.25)
        #expect(summary.chartBuckets.count == 1)
        #expect(summary.chartBuckets[0].total == 120)
    }

    @Test func rejectsWrongPeriodAndInvalidTotals() {
        #expect(throws: (any Error).self) {
            try MagpieClient.decodeUsage(Data(#"{"period":"30d","input":0,"output":0,"calls":0,"cost":0}"#.utf8), period: .weekly)
        }
        #expect(throws: (any Error).self) {
            try MagpieClient.decodeUsage(Data(#"{"period":"today","input":-1,"output":0,"calls":0,"cost":0}"#.utf8), period: .daily)
        }
    }

    @Test func malformedPayloadIsDataFailureRatherThanConnectionFailure() {
        #expect(throws: MagpieFailure.invalidResponse) { try MagpieClient.decodeQuotas(Data("{}".utf8)) }
        #expect(throws: MagpieFailure.invalidResponse) {
            try MagpieClient.decodeUsage(Data(#"{"period":"today","input":0,"output":0}"#.utf8), period: .daily)
        }
    }

    @Test func emptyUsageIsAValidZero() throws {
        let summary = try MagpieClient.decodeUsage(Data(#"{"period":"today","bucket":"hour","input":0,"output":0,"calls":0,"cost":0,"models":[],"series":[]}"#.utf8), period: .daily)
        #expect(summary.total == 0)
    }

    @Test func cumulativeKeepsWeeklyBucketsWithoutInventingDailyUsage() throws {
        let data = Data(#"{"period":"all","bucket":"week","input":100,"output":20,"calls":0,"cost":0,"series":[{"time":"2026-10-05T00:00:00+08:00","input":100,"output":20}]}"#.utf8)
        let summary = try MagpieClient.decodeUsage(data, period: .cumulative)
        #expect(summary.chartBuckets.count == 1)
        #expect(summary.chartBuckets[0].total == 120)
        #expect(summary.chartBuckets[0].end.timeIntervalSince(summary.chartBuckets[0].start) == 7 * 86400)
    }

    @Test func endpointIsRestrictedToLoopback() throws {
        #expect(throws: (any Error).self) { try MagpieClient(baseURL: URL(string: "https://example.com")!) }
        #expect(throws: (any Error).self) { try MagpieClient(baseURL: URL(string: "http://127.0.0.1")!) }
        #expect(throws: (any Error).self) { try MagpieClient(baseURL: URL(string: "http://127.0.0.1@evil.test:3425")!) }
        #expect(try MagpieClient(baseURL: URL(string: "http://127.0.0.1:4321")!).baseURL.port == 4321)
    }
}
