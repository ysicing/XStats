// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import AIUsage
import Foundation
import Testing

@Suite struct CodexCredentialStoreTests {
    @Test func resolvesConfiguredHomeBeforeDefaultLocations() {
        let home = URL(fileURLWithPath: "/Users/test")

        let overridden = CodexCredentialStore.candidateURLs(environment: ["CODEX_HOME": "/tmp/codex"], home: home)
        let defaults = CodexCredentialStore.candidateURLs(environment: [:], home: home)

        #expect(overridden.map(\.path) == ["/tmp/codex/auth.json"])
        #expect(defaults.map(\.path) == [
            "/Users/test/.config/codex/auth.json",
            "/Users/test/.codex/auth.json",
        ])
    }

    @Test func parsesOAuthCredentialsWithoutRetainingRefreshMaterial() throws {
        let data = Data(#"{"tokens":{"access_token":"access","refresh_token":"refresh","id_token":"id","account_id":"account"}}"#.utf8)

        let credentials = try CodexCredentialStore.parse(data)

        #expect(credentials.accessToken == "access")
        #expect(credentials.accountID == "account")
    }

    @Test func rejectsAPIKeyOnlyAuthentication() {
        let data = Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8)

        #expect(throws: AIUsageFailure.apiKeyUnsupported) {
            try CodexCredentialStore.parse(data)
        }
    }

    @Test func rejectsMalformedAuthenticationWithoutIncludingInput() {
        let secret = "secret-that-must-not-escape"
        let data = Data("{\"tokens\":{\"access_token\":\"\(secret)\"".utf8)

        do {
            _ = try CodexCredentialStore.parse(data)
            Issue.record("Expected invalid credentials")
        } catch {
            #expect(error as? AIUsageFailure == .invalidCredentials)
            #expect(!String(describing: error).contains(secret))
        }
    }
}

@Suite struct CodexUsageMapperTests {
    @Test func acceptsZeroAndOnePercentAndRejectsNonfiniteCredits() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000},"secondary_window":{"used_percent":1,"limit_window_seconds":604800}},"credits":{"balance":"inf"}}"#.utf8)
        let snapshot = try CodexUsageMapper.map(data: data, headers: [:], now: Date())
        #expect(snapshot.windows.map(\.usedPercent) == [0, 1])
        #expect(snapshot.remainingCredits == nil)
    }
    @Test func classifiesWindowsByDurationAndMapsSparkAndCredits() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data(#"""
        {
          "plan_type": "prolite",
          "rate_limit": {
            "primary_window": {
              "used_percent": 73,
              "limit_window_seconds": 604800,
              "reset_at": 1800100000
            },
            "secondary_window": {
              "used_percent": 21,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 600
            }
          },
          "additional_rate_limits": [{
            "limit_name": "GPT-Codex-Spark",
            "rate_limit": {
              "primary_window": {"used_percent": 91, "limit_window_seconds": 18000},
              "secondary_window": {"used_percent": 44, "limit_window_seconds": 604800}
            }
          }],
          "credits": {"balance": "820.9"}
        }
        """#.utf8)

        let snapshot = try CodexUsageMapper.map(data: data, headers: [:], now: now)

        #expect(snapshot.planName == "Pro 5x")
        #expect(snapshot.windows.map(\.kind) == [.session, .weekly, .sparkSession, .sparkWeekly])
        #expect(snapshot.windows.map(\.usedPercent) == [21, 73, 91, 44])
        #expect(snapshot.window(.session)?.resetsAt == now.addingTimeInterval(600))
        #expect(snapshot.window(.weekly)?.resetsAt == Date(timeIntervalSince1970: 1_800_100_000))
        #expect(snapshot.remainingCredits == 820.9)
    }

    @Test func usesHeadersWhenResponseOmitsPercentages() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"limit_window_seconds":18000},"secondary_window":{"limit_window_seconds":604800}}}"#.utf8)

        let snapshot = try CodexUsageMapper.map(
            data: data,
            headers: [
                "X-Codex-Primary-Used-Percent": "17.25",
                "x-codex-secondary-used-percent": "68",
            ],
            now: Date()
        )

        #expect(snapshot.windows.map(\.usedPercent) == [17.25, 68])
    }

    @Test func rejectsBooleanPercentInsteadOfTreatingItAsOne() {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":true,"limit_window_seconds":18000}}}"#.utf8)

        #expect(throws: AIUsageFailure.invalidResponse) {
            try CodexUsageMapper.map(data: data, headers: [:], now: Date())
        }
    }
}

@Suite struct AIUsageSnapshotTests {
    @Test func automaticFocusChoosesHighestUnderlyingUsage() throws {
        let snapshot = AIUsageSnapshot(
            provider: .codex,
            planName: "Pro 20x",
            windows: [
                AIQuotaWindow(kind: .session, usedPercent: 32, resetsAt: nil),
                AIQuotaWindow(kind: .weekly, usedPercent: 87, resetsAt: nil),
            ],
            remainingCredits: nil,
            fetchedAt: Date()
        )

        let focus = try #require(snapshot.attentionWindow)

        #expect(focus.kind == .weekly)
        #expect(snapshot.displayedPercent(for: focus, mode: .remaining) == 13)
        #expect(snapshot.displayedPercent(for: focus, mode: .used) == 87)
    }
}
