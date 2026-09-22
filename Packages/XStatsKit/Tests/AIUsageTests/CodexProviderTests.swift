// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import AIUsage
import Foundation
import Testing

private actor HTTPClient: AIHTTPClient {
    private var responses: [AIHTTPResponse]
    private(set) var requests: [AIHTTPRequest] = []

    init(_ responses: [AIHTTPResponse]) { self.responses = responses }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.cannotConnectToHost) }
        return responses.removeFirst()
    }

    func capturedRequests() -> [AIHTTPRequest] { requests }
}

@Suite struct CodexProviderTests {
    @Test func sendsReadOnlyCredentialsToUsageEndpoint() async throws {
        let body = Data(#"{"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000}}}"#.utf8)
        let http = HTTPClient([AIHTTPResponse(statusCode: 200, headers: [:], body: body)])
        let provider = CodexProvider(
            credentials: { CodexCredentials(accessToken: "access", accountID: "account") },
            http: http,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = try await provider.fetch()
        let request = try #require(await http.capturedRequests().first)

        #expect(snapshot.window(.session)?.usedPercent == 25)
        #expect(request.method == .get)
        #expect(request.url == URL(string: "https://chatgpt.com/backend-api/wham/usage"))
        #expect(request.headers["Authorization"] == "Bearer access")
        #expect(request.headers["ChatGPT-Account-Id"] == "account")
        #expect(request.body == nil)
    }

    @Test func classifiesAuthenticationAndServerFailures() async {
        let credentials: @Sendable () throws -> CodexCredentials = {
            CodexCredentials(accessToken: "access", accountID: nil)
        }
        let unauthorized = CodexProvider(
            credentials: credentials,
            http: HTTPClient([AIHTTPResponse(statusCode: 401, headers: [:], body: Data())])
        )
        let unavailable = CodexProvider(
            credentials: credentials,
            http: HTTPClient([AIHTTPResponse(statusCode: 503, headers: [:], body: Data())])
        )

        await #expect(throws: AIUsageFailure.unauthorized) { try await unauthorized.fetch() }
        await #expect(throws: AIUsageFailure.server(503)) { try await unavailable.fetch() }
    }

    @Test func parsesRetryAfterWithoutRetryingInsideProvider() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let http = HTTPClient([AIHTTPResponse(statusCode: 429, headers: ["Retry-After": "120"], body: Data())])
        let provider = CodexProvider(
            credentials: { CodexCredentials(accessToken: "access", accountID: nil) },
            http: http,
            now: { now }
        )

        do {
            _ = try await provider.fetch()
            Issue.record("Expected rate limit")
        } catch {
            #expect(error as? AIUsageFailure == .rateLimited(now.addingTimeInterval(120)))
        }
        #expect(await http.capturedRequests().count == 1)
    }
}
