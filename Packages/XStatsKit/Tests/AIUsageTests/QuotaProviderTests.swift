// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import AIUsage
import Darwin
import Foundation
import Testing

private actor StubQuotaHTTPClient: QuotaHTTPClient {
    let status: Int
    let body: Data
    private(set) var requests: [URLRequest] = []

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return (body, status)
    }

    func lastRequest() -> URLRequest? { requests.last }
}

@Suite struct QuotaProviderTests {
    @Test func quotaCacheKeepsOnlyTheLatestSnapshotPerProvider() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xstats-quota-store-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let store = try AIQuotaCacheStore(url: url)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let codex = AIQuotaSnapshot(provider: .codex,
            windows: [AIQuotaWindow(kind: .weekly, usedPercent: 25, resetsAt: date)], fetchedAt: date)
        let updatedCodex = AIQuotaSnapshot(provider: .codex,
            windows: [AIQuotaWindow(kind: .weekly, usedPercent: 40, resetsAt: date)], fetchedAt: date)
        let claude = AIQuotaSnapshot(provider: .claude,
            windows: [AIQuotaWindow(kind: .fableWeekly, usedPercent: 70, resetsAt: nil)],
            fetchedAt: date, source: .sub2api)
        try store.save(codex)
        try store.save(claude)
        try store.save(updatedCodex)

        let reopened = try AIQuotaCacheStore(url: url)
        #expect(try reopened.load() == [.codex: updatedCodex, .claude: claude])
        try reopened.clear(.codex)
        #expect(try reopened.load() == [.claude: claude])
    }

    @Test func quotaPresentationUsesRemainingAmountAndTimeUntilReset() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let weekly = AIQuotaWindow(kind: .weekly, usedPercent: 74,
            resetsAt: now.addingTimeInterval(7 * 24 * 3600 / 4))
        let session = AIQuotaWindow(kind: .session, usedPercent: 20,
            resetsAt: now.addingTimeInterval(2.5 * 3600))

        #expect(weekly.remainingPercent == 26)
        #expect(try #require(weekly.remainingTimeFraction(at: now)) == 0.25)
        #expect(try #require(session.remainingTimeFraction(at: now)) == 0.5)
        #expect(weekly.remainingTimeFraction(at: now.addingTimeInterval(8 * 24 * 3600)) == 0)
        #expect(weekly.remainingTimeFraction(at: now.addingTimeInterval(-8 * 24 * 3600)) == 1)
    }

    @Test func quotaWithoutResetTimeHasNoTimeProgress() {
        let window = AIQuotaWindow(kind: .weekly, usedPercent: 74, resetsAt: nil)
        #expect(window.remainingTimeFraction(at: Date()) == nil)
    }

    @Test func quotaCacheIgnoresRemovedSub2APIStats() throws {
        // 已安装版本可能把该字段写入 SQLite 快照；移除展示后仍应读出额度。
        let data = Data(#"{"kind":"weekly","usedPercent":74,"resetsAt":null,"sub2apiStats":{"requests":8,"tokens":12000}}"#.utf8)
        let window = try JSONDecoder().decode(AIQuotaWindow.self, from: data)
        #expect(window.remainingPercent == 26)
    }

    @Test func codexMapsWeeklyWindowEvenWhenServerReversesSlots() async throws {
        let http = StubQuotaHTTPClient(body: #"{"rate_limit":{"primary_window":{"used_percent":61,"limit_window_seconds":604800,"reset_at":1800000000},"secondary_window":{"used_percent":18,"limit_window_seconds":18000,"reset_at":1799500000}}}"#)
        let provider = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "test-token", accountID: "account-1") }, http: http)

        let result = try await provider.fetch()

        #expect(result.window(.weekly)?.usedPercent == 61)
        #expect(result.window(.session)?.usedPercent == 18)
        let request = try #require(await http.lastRequest())
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func codexShowsOnlyQuotaWindowsReturnedForEachPlan() throws {
        let now = Date(timeIntervalSince1970: 1_799_000_000)
        let plus = Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":35,"limit_window_seconds":18000,"reset_after_seconds":3600},"secondary_window":null}}"#.utf8)
        let pro = Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":74,"limit_window_seconds":604800,"reset_after_seconds":86400},"secondary_window":null}}"#.utf8)

        let plusSnapshot = try CodexQuotaProvider.parse(plus, now: now)
        #expect(plusSnapshot.window(.session)?.remainingPercent == 65)
        #expect(plusSnapshot.window(.weekly) == nil)

        let proSnapshot = try CodexQuotaProvider.parse(pro, now: now)
        #expect(proSnapshot.window(.session) == nil)
        #expect(proSnapshot.window(.weekly)?.remainingPercent == 26)
    }

    @Test func claudeMapsFiveHourAndWeeklyBuckets() async throws {
        let http = StubQuotaHTTPClient(body: #"{"five_hour":{"utilization":22.5,"resets_at":"2026-09-23T10:00:00Z"},"seven_day":{"utilization":72,"resets_at":"2026-09-29T10:00:00Z"},"seven_day_sonnet":{"utilization":81,"resets_at":"2026-09-29T10:00:00Z"}}"#)
        let provider = ClaudeQuotaProvider(credentials: { "claude-test-token" }, http: http)

        let result = try await provider.fetch()

        #expect(result.window(.session)?.usedPercent == 22.5)
        #expect(result.window(.weekly)?.usedPercent == 72)
        #expect(result.window(.sonnetWeekly)?.usedPercent == 81)
        let request = try #require(await http.lastRequest())
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer claude-test-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func codexFallsBackToPrimaryAndSecondaryWhenDurationIsOmitted() throws {
        let now = Date(timeIntervalSince1970: 1_799_000_000)
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":14,"reset_after_seconds":3600},"secondary_window":{"used_percent":84,"reset_after_seconds":7200}}}"#.utf8)

        let result = try CodexQuotaProvider.parse(data, now: now)

        #expect(result.window(.session)?.usedPercent == 14)
        #expect(result.window(.weekly)?.usedPercent == 84)
        #expect(result.window(.weekly)?.resetsAt == now.addingTimeInterval(7200))
    }

    @Test func unauthorizedDoesNotReturnOldOrEmptyQuota() async {
        let http = StubQuotaHTTPClient(status: 401, body: "{}")
        let provider = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "test", accountID: nil) }, http: http)
        do {
            _ = try await provider.fetch()
            Issue.record("Expected an authentication failure")
        } catch let error as AIQuotaFailure {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test func cloudflareHTMLForbiddenIsNotReportedAsExpiredLogin() async {
        let http = StubQuotaHTTPClient(status: 403, body: "<html>Unable to load site</html>")
        let provider = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "test", accountID: nil) }, http: http)
        do {
            _ = try await provider.fetch()
            Issue.record("Expected a transport failure")
        } catch let error as AIQuotaFailure {
            #expect(error == .network)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test func codexAppServerParsesWeeklyWindowAndRecoversBlockedDirectRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = Data(#"{"id":1,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":1800003600},"secondary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800001800}}}}}"#.utf8)
        let fallback = try CodexAppServerQuotaClient.parse(response, now: now)
        #expect(fallback.window(.weekly)?.usedPercent == 23)
        #expect(fallback.window(.session)?.usedPercent == 12)
        #expect(fallback.window(.weekly)?.resetsAt == now.addingTimeInterval(3600))

        let http = StubQuotaHTTPClient(status: 403, body: "<html>Unable to load site</html>")
        let provider = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "test", accountID: nil) },
                                          http: http, appServer: { fallback })
        let result = try await provider.fetch()
        #expect(result == fallback)
        #expect(await http.lastRequest() == nil, "Codex App Server should be queried before direct HTTP")
    }

    @Test func codexAppServerClosingStdinDoesNotCrashQuotaRefresh() throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("xstats-codex-closed-stdin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: script) }
        try "#!/bin/sh\nexec 0<&-\nprintf '{\"id\":0,\"result\":{}}\\n'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        #expect(Darwin.chmod(script.path, 0o700) == 0)

        #expect(throws: AIQuotaFailure.network) {
            try CodexAppServerQuotaClient.readRateLimits(using: script)
        }
    }

    @Test func codexDirectForbiddenJSONStillMeansUnauthorized() async {
        let http = StubQuotaHTTPClient(status: 403, body: #"{"error":"invalid_token"}"#)
        let provider = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "test", accountID: nil) }, http: http)
        do {
            _ = try await provider.fetch()
            Issue.record("Expected an authentication failure")
        } catch let error as AIQuotaFailure {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test func cancellingCodexAppServerDoesNotStartDirectRequest() async {
        let http = StubQuotaHTTPClient(body: #"{"rate_limit":{}}"#)
        let provider = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "test", accountID: nil) },
                                          http: http, appServer: { throw CancellationError() })
        do {
            _ = try await provider.fetch()
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(await http.lastRequest() == nil)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test func credentialParsersRejectAPIKeyOnlyAndExpiredClaudeToken() throws {
        #expect(throws: AIQuotaFailure.notConfigured) {
            try CodexQuotaCredentials.parse(Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8))
        }
        let expired = Data(#"{"claudeAiOauth":{"accessToken":"old","expiresAt":1000}}"#.utf8)
        #expect(throws: AIQuotaFailure.unauthorized) {
            try ClaudeQuotaCredentials.parse(expired, now: Date(timeIntervalSince1970: 2))
        }
    }
}
