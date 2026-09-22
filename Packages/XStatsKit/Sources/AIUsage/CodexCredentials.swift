// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    public let accountID: String?

    public init(accessToken: String, accountID: String?) {
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

public enum CodexCredentialStore {
    public static func candidateURLs(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        if let override = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return [URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("auth.json")]
        }
        return [
            home.appendingPathComponent(".config/codex/auth.json"),
            home.appendingPathComponent(".codex/auth.json"),
        ]
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> CodexCredentials {
        for url in candidateURLs(environment: environment, home: home) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else { throw AIUsageFailure.invalidCredentials }
            return try parse(data)
        }
        throw AIUsageFailure.notConfigured
    }

    public static func parse(_ data: Data) throws -> CodexCredentials {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageFailure.invalidCredentials
        }
        if let apiKey = string(object["OPENAI_API_KEY"]), !apiKey.isEmpty,
           object["tokens"] == nil {
            throw AIUsageFailure.apiKeyUnsupported
        }
        guard let tokens = object["tokens"] as? [String: Any],
              let accessToken = string(tokens["access_token"] ?? tokens["accessToken"]),
              !accessToken.isEmpty else {
            throw AIUsageFailure.invalidCredentials
        }
        return CodexCredentials(
            accessToken: accessToken,
            accountID: string(tokens["account_id"] ?? tokens["accountId"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
