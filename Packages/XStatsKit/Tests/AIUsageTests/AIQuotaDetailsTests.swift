// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AIUsage

@Suite struct AIQuotaDetailsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func appServerKeepsPlanCountAndEarliestAvailableExpiry() throws {
        let data = Data(#"{"result":{"accountId":"a","rateLimits":{"planType":"pro","primary":{"usedPercent":30,"windowDurationMins":10080}},"rateLimitResetCredits":{"availableCount":3,"credits":[{"status":"redeemed","expiresAt":1800000100},{"status":"available","expiresAt":1799999900},{"status":"available","expiresAt":null},{"status":"available","expiresAt":1800003000},{"status":"available","expiresAt":1800002000}]}}}"#.utf8)
        let credentials = CodexQuotaCredentials(token: "unused", accountID: "a", subscriptionValidUntil: now.addingTimeInterval(9000), subscriptionValidFrom: now.addingTimeInterval(-9000))
        let snapshot = try CodexAppServerQuotaClient.parse(data, now: now, credentials: credentials)
        #expect(snapshot.details?.plan == "pro")
        #expect(snapshot.details?.resetCredits == 3)
        #expect(snapshot.details?.resetCreditsExpireAt == now.addingTimeInterval(2000))
        #expect(snapshot.details?.subscriptionValidUntil == now.addingTimeInterval(9000))
        #expect(snapshot.details?.subscriptionValidFrom == now.addingTimeInterval(-9000))
        #expect(snapshot.details?.subscriptionRemainingFraction(at: now) == 0.5)
        let other = CodexQuotaCredentials(token: "unused", accountID: "other", subscriptionValidUntil: now.addingTimeInterval(9000), subscriptionValidFrom: now.addingTimeInterval(-9000))
        #expect(try CodexAppServerQuotaClient.parse(data, now: now, credentials: other).details?.subscriptionValidUntil == nil)
        #expect(try CodexAppServerQuotaClient.parse(data, now: now, credentials: other).details?.subscriptionValidFrom == nil)
    }

    @Test func countsAndUnknownExpiryStayDistinct() {
        for invalid: Any in [true, -1, 1.5, "3", Double.infinity] {
            #expect(AIQuotaDetails.parse(plan: nil, resets: ["availableCount": invalid], appServer: true, now: now).resetCredits == nil)
        }
        let zero = AIQuotaDetails.parse(plan: "unknown", resets: ["availableCount": 0], appServer: true, now: now)
        #expect(zero.plan == nil)
        #expect(zero.resetCredits == 0)
        #expect(zero.resetCreditsExpireAt == nil)
        let missing = AIQuotaDetails.parse(plan: "pro", resets: ["availableCount": 3], appServer: true, now: now)
        #expect(missing.resetCredits == 3)
        #expect(missing.resetCreditsExpireAt == nil)
    }

    @Test func subscriptionTermUsesMatchingIdentityAndNotJWTExpiry() throws {
        func auth(account: String = "a", until: Date?, start: Date? = nil, exp: Double = 1_900_000_000) throws -> Data {
            var subscription: [String: Any] = ["chatgpt_account_id": account]
            if let until { subscription["chatgpt_subscription_active_until"] = ISO8601DateFormatter().string(from: until) }
            if let start { subscription["chatgpt_subscription_active_start"] = ISO8601DateFormatter().string(from: start) }
            let payload = try JSONSerialization.data(withJSONObject: ["exp": exp, "https://api.openai.com/auth": subscription])
                .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "test", "account_id": "a", "id_token": "header.\(payload).signature"]])
        }
        let date = now.addingTimeInterval(3600)
        #expect(try CodexQuotaCredentials.parse(auth(until: date), now: now).subscriptionValidUntil == date)
        let start = now.addingTimeInterval(-3600)
        #expect(try CodexQuotaCredentials.parse(auth(until: date, start: start), now: now).subscriptionValidFrom == start)
        #expect(try CodexQuotaCredentials.parse(auth(until: date), now: now).subscriptionValidFrom == nil)
        #expect(try CodexQuotaCredentials.parse(auth(until: date, start: date), now: now).subscriptionValidFrom == nil)
        #expect(try CodexQuotaCredentials.parse(auth(until: date, start: now.addingTimeInterval(100)), now: now).subscriptionValidFrom == nil)
        #expect(try CodexQuotaCredentials.parse(auth(account: "b", until: date, start: start), now: now).subscriptionValidFrom == nil)
        #expect(try CodexQuotaCredentials.parse(auth(account: "b", until: date), now: now).subscriptionValidUntil == nil)
        #expect(try CodexQuotaCredentials.parse(auth(until: nil), now: now).subscriptionValidUntil == nil)
        #expect(try CodexQuotaCredentials.parse(auth(until: now.addingTimeInterval(-1)), now: now).subscriptionValidUntil == nil)
    }

    @Test func validityProgressRequiresRealBoundsAndClampsTime() {
        let start = now.addingTimeInterval(-9000)
        let end = now.addingTimeInterval(9000)
        let details = AIQuotaDetails(subscriptionValidUntil: end, subscriptionValidFrom: start)
        #expect(details.subscriptionRemainingFraction(at: now) == 0.5)
        #expect(details.subscriptionRemainingFraction(at: start.addingTimeInterval(-1)) == 1)
        #expect(details.subscriptionRemainingFraction(at: end.addingTimeInterval(1)) == 0)
        #expect(AIQuotaDetails(subscriptionValidUntil: end).subscriptionRemainingFraction(at: now) == nil)
        #expect(AIQuotaDetails(subscriptionValidUntil: start, subscriptionValidFrom: end).subscriptionRemainingFraction(at: now) == nil)
        #expect(AIQuotaDetails(subscriptionValidUntil: end, subscriptionValidFrom: end).subscriptionRemainingFraction(at: now) == nil)
        #expect(details.subscriptionRemainingFraction(at: Date(timeIntervalSince1970: .infinity)) == nil)
    }

    @Test func directDetailFailurePreservesQuotaAndCount() async throws {
        let http = DetailsHTTP(failure: true)
        let provider = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "test", accountID: "a") }, http: http)
        let result = try await provider.fetch()
        #expect(result.window(.weekly)?.usedPercent == 25)
        #expect(result.details?.plan == "pro")
        #expect(result.details?.resetCredits == 3)
        #expect(result.details?.resetCreditsExpireAt == nil)
        #expect(await http.paths == ["/backend-api/wham/usage", "/backend-api/wham/rate-limit-reset-credits"])
        #expect(await http.methods == ["GET", "GET"])
    }

    @Test func directReadsLatestResetDetailsAndNeverConsumes() async throws {
        let http = DetailsHTTP()
        let provider = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "test", accountID: "a") }, http: http)
        let result = try await provider.fetch()
        #expect(result.details?.resetCredits == 2)
        #expect(result.details?.resetCreditsExpireAt == ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z"))
        #expect(await http.methods == ["GET", "GET"])
        #expect(await http.detailTimeout == 4)
    }

    @Test func cancelledDetailLookupPropagatesCancellation() async {
        let http = DetailsHTTP(cancel: true)
        let provider = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "test", accountID: nil) }, http: http)
        await #expect(throws: CancellationError.self) { try await provider.fetch() }
        #expect(await http.paths.count == 2)
    }

    @Test func zeroResetCountSkipsExtraRequest() async throws {
        let http = DetailsHTTP(count: 0)
        let provider = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "test", accountID: nil) }, http: http)
        #expect(try await provider.fetch().details?.resetCredits == 0)
        #expect(await http.paths.count == 1)
    }

    @Test func cacheRoundTripsDetailsAndDecodesLegacySnapshot() throws {
        let legacy = Data(#"{"provider":"codex","windows":[{"kind":"weekly","usedPercent":25}],"fetchedAt":0,"source":"direct"}"#.utf8)
        let snapshot = try JSONDecoder().decode(AIQuotaSnapshot.self, from: legacy)
        #expect(snapshot.details == nil)
        var updated = snapshot
        updated.details = AIQuotaDetails(plan: "pro", subscriptionValidUntil: now, resetCredits: 3, resetCreditsExpireAt: now, subscriptionValidFrom: now.addingTimeInterval(-100))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let cache = try AIQuotaCacheStore(url: url)
        try cache.save(updated)
        #expect(try cache.load()[.codex] == updated)
        let encoded = String(decoding: try JSONEncoder().encode(updated), as: UTF8.self)
        #expect(!encoded.contains("accountId") && !encoded.contains("access_token"))
    }
}

private actor DetailsHTTP: QuotaHTTPClient {
    let failure: Bool
    let cancel: Bool
    let count: Int
    var paths: [String] = []
    var methods: [String] = []
    var detailTimeout: TimeInterval?
    init(failure: Bool = false, count: Int = 3, cancel: Bool = false) { self.failure = failure; self.count = count; self.cancel = cancel }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        paths.append(request.url!.path); methods.append(request.httpMethod ?? "GET")
        if request.url!.path.hasSuffix("/usage") {
            return (Data("{\"plan_type\":\"pro\",\"rate_limit_reset_credits\":{\"available_count\":\(count)},\"rate_limit\":{\"primary_window\":{\"used_percent\":25,\"limit_window_seconds\":604800}}}".utf8), 200)
        }
        detailTimeout = request.timeoutInterval
        if cancel { throw CancellationError() }
        if failure { return (Data(), 503) }
        return (Data(#"{"available_count":2,"credits":[{"status":"available","expires_at":"2099-02-01T00:00:00Z"},{"status":"available","expires_at":"2099-01-01T00:00:00Z"},{"status":"redeemed","expires_at":"2098-01-01T00:00:00Z"}]}"#.utf8), 200)
    }
}
