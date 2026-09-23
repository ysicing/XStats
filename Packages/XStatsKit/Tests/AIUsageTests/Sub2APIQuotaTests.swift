// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import AIUsage
import Foundation
import Testing

private actor StubSub2APIHTTPClient: QuotaHTTPClient {
    private var replies: [(Int, Data)]
    private var captured: [URLRequest] = []

    init(_ replies: [(Int, String)]) {
        self.replies = replies.map { ($0.0, Data($0.1.utf8)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        captured.append(request)
        guard !replies.isEmpty else { throw AIQuotaFailure.network }
        let (status, data) = replies.removeFirst()
        return (data, status)
    }

    func requests() -> [URLRequest] { captured }
}

private actor ConcurrentSub2APIHTTPClient: QuotaHTTPClient {
    private(set) var logins = 0

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.path.hasSuffix("/auth/login") == true {
            logins += 1
            try await Task.sleep(for: .milliseconds(30))
            return (Data(#"{"code":0,"data":{"access_token":"shared","expires_in":3600}}"#.utf8), 200)
        }
        if request.url?.path.hasSuffix("/usage") == true {
            return (Data(#"{"code":0,"data":{"five_hour":{"utilization":20,"remaining_seconds":1800}}}"#.utf8), 200)
        }
        let platform = request.url?.path.hasSuffix("/43") == true ? "anthropic" : "openai"
        return (Data("{\"code\":0,\"data\":{\"platform\":\"\(platform)\",\"extra\":{}}}".utf8), 200)
    }
}

@MainActor
private final class InMemorySub2APISecretStore: Sub2APISecretStore {
    var value: String?
    var failWrites = false
    func read() throws -> String? { value }
    func write(_ password: String) throws {
        if failWrites { throw Sub2APIConfigurationError.missingCredentials }
        value = password
    }
    func delete() throws { value = nil }
}

@Suite struct Sub2APIQuotaTests {
    private func configuration(provider: AIProviderID = .codex, accountID: String = "42") throws -> Sub2APIConfiguration {
        try Sub2APIConfiguration(address: "https://sub.example.com/prefix/", email: "admin@example.com",
                                 password: "secret", accountID: accountID, provider: provider)
    }

    @Test @MainActor func configurationRequiresHTTPSAndStoresPasswordSeparately() throws {
        #expect(throws: Sub2APIConfigurationError.invalidAddress) {
            try Sub2APIConfiguration(address: "http://sub.example.com", email: "admin@example.com",
                                     password: "secret", accountID: "42")
        }
        #expect(throws: Sub2APIConfigurationError.invalidAccountID) {
            try Sub2APIConfiguration(address: "https://sub.example.com", email: "admin@example.com",
                                     password: "secret", accountID: "../42")
        }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let secrets = InMemorySub2APISecretStore()
        let store = Sub2APISettingsStore(defaults: defaults, secrets: secrets)
        let codexConfiguration = try configuration()
        try store.save(codexConfiguration)
        let saved = try #require(try store.load())
        #expect(saved.baseURL.absoluteString == "https://sub.example.com/prefix")
        #expect(saved.accountID == 42)
        #expect(defaults.dictionary(forKey: "aiUsage.sub2api")?["password"] == nil)
        #expect(secrets.value == "secret")
        try store.clear()
        let cleared = try store.load()
        #expect(cleared == nil)

        secrets.failWrites = true
        #expect(throws: Sub2APIConfigurationError.missingCredentials) {
            try store.save(codexConfiguration)
        }
        #expect(defaults.dictionary(forKey: "aiUsage.sub2api") == nil)

        secrets.failWrites = false
        let claudeSecrets = InMemorySub2APISecretStore()
        let claudeStore = Sub2APISettingsStore(provider: .claude, defaults: defaults, secrets: claudeSecrets)
        let claude = try configuration(provider: .claude, accountID: "43")
        try claudeStore.save(claude)
        #expect(try claudeStore.load()?.provider == .claude)
        #expect(defaults.dictionary(forKey: "aiUsage.sub2api") == nil)
        #expect(defaults.dictionary(forKey: "aiUsage.sub2api.claude")?["accountID"] as? Int == 43)
        #expect(claudeSecrets.value == "secret")
        #expect(throws: Sub2APIConfigurationError.providerMismatch) {
            try store.save(claude)
        }
    }

    @Test func detailedUsageUsesCachedQueryAndMapsBothWindows() async throws {
        let http = StubSub2APIHTTPClient([
            (200, #"{"code":0,"data":{"access_token":"short-lived"}}"#),
            (200, #"{"code":0,"data":{"platform":"openai","extra":{}}}"#),
            (200, #"{"code":0,"data":{"five_hour":{"utilization":35,"remaining_seconds":3600},"seven_day":{"utilization":72,"resets_at":"2026-09-26T17:35:00Z"}}}"#),
        ])
        let result = try await Sub2APIQuotaClient(http: http).fetch(configuration: configuration())
        #expect(result.source == .sub2api)
        #expect(result.window(.session)?.remainingPercent == 65)
        #expect(result.window(.weekly)?.remainingPercent == 28)
        #expect(result.window(.fableWeekly) == nil)
        #expect(result.window(.session)?.resetsAt != nil)

        let requests = await http.requests()
        #expect(requests.count == 3)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.path == "/prefix/api/v1/auth/login")
        #expect(requests[1].url?.path == "/prefix/api/v1/admin/accounts/42")
        #expect(requests[2].url?.path == "/prefix/api/v1/admin/accounts/42/usage")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer short-lived")
        let query = URLComponents(url: try #require(requests[2].url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "force" })?.value == "false")
        #expect(query?.first(where: { $0.name == "source" })?.value == "active")
    }

    @Test func olderServerFallsBackToAccountExtra() async throws {
        let http = StubSub2APIHTTPClient([
            (200, #"{"code":0,"data":{"access_token":"short-lived"}}"#),
            (200, #"{"code":0,"data":{"platform":"openai","extra":{"session_window_utilization":0.25,"passive_usage_7d_utilization":0.6,"passive_usage_7d_reset":1800000000},"session_window_end":"2026-09-26T17:35:00Z"}}"#),
            (404, "{}"),
        ])
        let result = try await Sub2APIQuotaClient(http: http).fetch(configuration: configuration())
        #expect(result.window(.session)?.usedPercent == 25)
        #expect(result.window(.weekly)?.usedPercent == 60)
        #expect(result.window(.fableWeekly) == nil)
        #expect(await http.requests().count == 3)
    }

    @Test func transportFailureDoesNotRepeatAgainstAccountEndpoint() async throws {
        let http = StubSub2APIHTTPClient([
            (200, #"{"code":0,"data":{"access_token":"short-lived"}}"#),
            (200, #"{"code":0,"data":{"platform":"openai","extra":{}}}"#),
        ])
        let client = Sub2APIQuotaClient(http: http)
        do {
            _ = try await client.fetch(configuration: configuration())
            Issue.record("Expected a transport failure")
        } catch let failure as AIQuotaFailure {
            #expect(failure == .sub2apiNetwork)
        }
        #expect(await http.requests().count == 3)
    }

    @Test func codexUsesManualSourceOnlyWhenAutomaticQuotaFails() async throws {
        let configuration = try configuration()
        let fallbackHTTP = StubSub2APIHTTPClient([
            (200, #"{"code":0,"data":{"access_token":"short-lived"}}"#),
            (200, #"{"code":0,"data":{"platform":"openai","extra":{}}}"#),
            (200, #"{"code":0,"data":{"five_hour":{"utilization":20,"remaining_seconds":1800}}}"#),
        ])
        let fallback = Sub2APIQuotaClient(http: fallbackHTTP)
        let missingCLI = CodexQuotaProvider(credentials: { throw AIQuotaFailure.notConfigured },
            http: StubSub2APIHTTPClient([]), sub2api: fallback,
            sub2apiConfiguration: { configuration })
        let manual = try await missingCLI.fetch()
        #expect(manual.source == .sub2api)
        #expect(manual.window(.session)?.remainingPercent == 80)

        let directHTTP = StubSub2APIHTTPClient([
            (200, #"{"rate_limit":{"primary_window":{"used_percent":74,"limit_window_seconds":604800}}}"#),
        ])
        let direct = CodexQuotaProvider(credentials: { CodexQuotaCredentials(token: "cli-token", accountID: nil) },
            http: directHTTP, sub2api: fallback, sub2apiConfiguration: { configuration })
        let automatic = try await direct.fetch()
        #expect(automatic.source == .direct)
        #expect(automatic.window(.weekly)?.remainingPercent == 26)
        #expect(await fallbackHTTP.requests().count == 3)
    }

    @Test func claudeUsesItsOwnManualAccountWhenLocalCredentialsAreMissing() async throws {
        let configuration = try configuration(provider: .claude, accountID: "43")
        let fallbackHTTP = StubSub2APIHTTPClient([
            (200, #"{"code":0,"data":{"access_token":"shared"}}"#),
            (200, #"{"code":0,"data":{"platform":"anthropic","extra":{"passive_usage_7d_oi_utilization":0.3,"passive_usage_7d_oi_reset":1800000000}}}"#),
            (200, #"{"code":0,"data":{"five_hour":{"utilization":15,"remaining_seconds":1800},"seven_day":{"utilization":40},"seven_day_sonnet":{"utilization":55}}}"#),
        ])
        let fallback = Sub2APIQuotaClient(http: fallbackHTTP)
        let missingCLI = ClaudeQuotaProvider(credentials: { throw AIQuotaFailure.notConfigured },
            http: StubSub2APIHTTPClient([]), sub2api: fallback,
            sub2apiConfiguration: { configuration })
        let manual = try await missingCLI.fetch()
        #expect(manual.provider == .claude)
        #expect(manual.source == .sub2api)
        #expect(manual.window(.session)?.remainingPercent == 85)
        #expect(manual.window(.weekly)?.remainingPercent == 60)
        #expect(manual.window(.sonnetWeekly)?.remainingPercent == 45)
        #expect(manual.window(.fableWeekly)?.remainingPercent == 70)
        #expect(await fallbackHTTP.requests().count == 3)

        let directHTTP = StubSub2APIHTTPClient([
            (200, #"{"five_hour":{"utilization":20}}"#),
        ])
        let direct = ClaudeQuotaProvider(credentials: { "claude-token" }, http: directHTTP,
            sub2api: fallback, sub2apiConfiguration: { configuration })
        let automatic = try await direct.fetch()
        #expect(automatic.provider == .claude)
        #expect(automatic.source == .direct)
        #expect(await fallbackHTTP.requests().count == 3)
    }

    @Test func detailedClaudeFableWindowIsUsedOnlyWhenServerReturnsAValue() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let present = Data(#"{"code":0,"data":{"five_hour":{"utilization":12},"seven_day_fable":{"utilization":37,"remaining_seconds":86400}}}"#.utf8)
        let missing = Data(#"{"code":0,"data":{"five_hour":{"utilization":12},"seven_day_fable":null}}"#.utf8)

        let fable = try Sub2APIQuotaClient.parseUsage(present, now: now, provider: .claude)
        #expect(fable.window(.fableWeekly)?.remainingPercent == 63)
        #expect(fable.window(.fableWeekly)?.resetsAt == now.addingTimeInterval(86400))
        let unavailable = try Sub2APIQuotaClient.parseUsage(missing, now: now, provider: .claude)
        #expect(unavailable.window(.fableWeekly) == nil)
    }

    @Test func mismatchedAccountPlatformIsRejectedBeforeUsageQuery() async throws {
        let http = StubSub2APIHTTPClient([
            (200, #"{"code":0,"data":{"access_token":"short-lived"}}"#),
            (200, #"{"code":0,"data":{"platform":"openai","extra":{}}}"#),
        ])
        do {
            _ = try await Sub2APIQuotaClient(http: http)
                .fetch(configuration: configuration(provider: .claude, accountID: "43"))
            Issue.record("Expected a platform mismatch")
        } catch let failure as AIQuotaFailure {
            #expect(failure == .sub2apiAccountMismatch)
        }
        #expect(await http.requests().count == 2)
    }

    @Test func concurrentRefreshesShareOneAdminLogin() async throws {
        let http = ConcurrentSub2APIHTTPClient()
        let client = Sub2APIQuotaClient(http: http)
        let codex = try configuration()
        let claude = try configuration(provider: .claude, accountID: "43")
        async let first = client.fetch(configuration: codex)
        async let second = client.fetch(configuration: claude)
        let (one, two) = try await (first, second)
        #expect(one.window(.session)?.remainingPercent == 80)
        #expect(two.window(.session)?.remainingPercent == 80)
        #expect(one.provider == .codex)
        #expect(two.provider == .claude)
        #expect(await http.logins == 1)
    }
}
