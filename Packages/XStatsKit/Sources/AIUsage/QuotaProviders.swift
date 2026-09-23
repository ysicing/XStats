// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security
import LocalAuthentication

public enum AIQuotaKind: String, Sendable, Identifiable {
    case session, weekly, fableWeekly, opusWeekly, sonnetWeekly
    public var id: Self { self }
}

public struct AIQuotaWindow: Equatable, Sendable, Identifiable {
    public let kind: AIQuotaKind
    public let usedPercent: Double
    public let resetsAt: Date?
    public var id: AIQuotaKind { kind }

    public var remainingPercent: Double { 100 - usedPercent }

    /// 以服务端给出的重置时间为终点；没有重置时间时不能推断窗口进度。
    public func remainingTimeFraction(at now: Date) -> Double? {
        guard let resetsAt else { return nil }
        let duration: TimeInterval = kind == .session ? 5 * 3600 : 7 * 24 * 3600
        return min(1, max(0, resetsAt.timeIntervalSince(now) / duration))
    }
}

public struct AIQuotaSnapshot: Equatable, Sendable {
    public let provider: AIProviderID
    public let windows: [AIQuotaWindow]
    public let fetchedAt: Date
    public let source: AIQuotaSource

    public init(provider: AIProviderID, windows: [AIQuotaWindow], fetchedAt: Date,
                source: AIQuotaSource = .direct) {
        self.provider = provider
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.source = source
    }

    public func window(_ kind: AIQuotaKind) -> AIQuotaWindow? { windows.first { $0.kind == kind } }
}

public enum AIQuotaSource: Equatable, Sendable {
    case direct, sub2api
}

public enum AIQuotaFailure: Error, Equatable, Sendable {
    case notConfigured, unauthorized, rateLimited, network, invalidResponse
    case sub2apiConfiguration, sub2apiUnauthorized, sub2apiNetwork, sub2apiInvalidResponse, sub2apiAccountMismatch

    public var preservesLastGood: Bool {
        switch self {
        case .notConfigured, .unauthorized, .sub2apiConfiguration, .sub2apiUnauthorized, .sub2apiAccountMismatch: false
        case .rateLimited, .network, .invalidResponse, .sub2apiNetwork, .sub2apiInvalidResponse: true
        }
    }
}

public protocol AIQuotaProvider: Sendable {
    var id: AIProviderID { get }
    func fetch() async throws -> AIQuotaSnapshot
}

protocol QuotaHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

actor URLSessionQuotaHTTPClient: QuotaHTTPClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration, delegate: RejectQuotaRedirects(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIQuotaFailure.network }
        return (data, response.statusCode)
    }
}

/// Bearer 凭据只发向请求的初始地址；拒绝重定向，避免转发 Authorization。
private final class RejectQuotaRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

struct CodexQuotaCredentials: Sendable {
    let token: String
    let accountID: String?

    static func parse(_ data: Data) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIQuotaFailure.notConfigured
        }
        // OPENAI_API_KEY 不是 ChatGPT 订阅用量凭据。
        guard let tokens = object["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw AIQuotaFailure.notConfigured
        }
        return Self(token: token, accountID: tokens["account_id"] as? String)
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Self {
        let candidates: [URL]
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            candidates = [URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).appendingPathComponent("auth.json")]
        } else {
            candidates = [home.appendingPathComponent(".codex/auth.json"),
                          home.appendingPathComponent(".config/codex/auth.json")]
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { throw AIQuotaFailure.notConfigured }
            return try parse(data)
        }
        throw AIQuotaFailure.notConfigured
    }
}

struct ClaudeQuotaCredentials: Sendable {
    let token: String

    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw AIQuotaFailure.notConfigured
        }
        if let expiry = oauth["expiresAt"] as? NSNumber,
           Date(timeIntervalSince1970: expiry.doubleValue / 1000) <= now { throw AIQuotaFailure.unauthorized }
        return Self(token: token)
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        let root = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent(".claude")
        let url = root.appendingPathComponent(".credentials.json")
        var fileFailure: AIQuotaFailure?
        if let data = try? Data(contentsOf: url) {
            do { return try parse(data).token }
            catch let failure as AIQuotaFailure { fileFailure = failure }
        }

        // Claude CLI 部分版本只把 OAuth 保存到钥匙串。后台读取不允许弹出授权框。
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecAttrAccount: NSUserName(),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { throw fileFailure ?? AIQuotaFailure.notConfigured }
        return try parse(data).token
    }
}

public actor CodexQuotaProvider: AIQuotaProvider {
    public nonisolated let id = AIProviderID.codex
    private let credentials: @Sendable () throws -> CodexQuotaCredentials
    private let http: any QuotaHTTPClient
    private let sub2api: (any Sub2APIQuotaFetching)?
    private let sub2apiConfiguration: @Sendable () async throws -> Sub2APIConfiguration?

    public init() {
        credentials = { try CodexQuotaCredentials.load() }
        http = URLSessionQuotaHTTPClient()
        sub2api = Sub2APIQuotaClient.shared
        sub2apiConfiguration = { try await Sub2APISettingsStore().load() }
    }

    init(credentials: @escaping @Sendable () throws -> CodexQuotaCredentials, http: any QuotaHTTPClient,
         sub2api: (any Sub2APIQuotaFetching)? = nil,
         sub2apiConfiguration: @escaping @Sendable () async throws -> Sub2APIConfiguration? = { nil }) {
        self.credentials = credentials
        self.http = http
        self.sub2api = sub2api
        self.sub2apiConfiguration = sub2apiConfiguration
    }

    public func fetch() async throws -> AIQuotaSnapshot {
        do { return try await fetchDirect() }
        catch let directFailure as AIQuotaFailure {
            guard let sub2api else { throw directFailure }
            let configuration: Sub2APIConfiguration?
            do { configuration = try await sub2apiConfiguration() }
            catch { throw AIQuotaFailure.sub2apiConfiguration }
            guard let configuration else { throw directFailure }
            guard configuration.provider == .codex else { throw AIQuotaFailure.sub2apiConfiguration }
            return try await sub2api.fetch(configuration: configuration)
        }
    }

    private func fetchDirect() async throws -> AIQuotaSnapshot {
        let credential = try credentials()
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XStats AIUsage", forHTTPHeaderField: "User-Agent")
        if let accountID = credential.accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let data = try await quotaResponse(for: request, using: http)
        return try Self.parse(data, now: Date())
    }

    static func parse(_ data: Data, now: Date) throws -> AIQuotaSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = object["rate_limit"] as? [String: Any] else { throw AIQuotaFailure.invalidResponse }
        var selected: [AIQuotaKind: (window: AIQuotaWindow, exact: Bool)] = [:]
        for name in ["primary_window", "secondary_window"] {
            guard let item = rate[name] as? [String: Any],
                  let used = (item["used_percent"] as? NSNumber)?.doubleValue,
                  used.isFinite, (0...100).contains(used) else { continue }
            let kind: AIQuotaKind
            let seconds = (item["limit_window_seconds"] as? NSNumber)?.intValue
            switch seconds {
            case 18_000: kind = .session
            case 604_800: kind = .weekly
            case nil: kind = name == "primary_window" ? .session : .weekly
            default: continue
            }
            let reset = (item["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                ?? (item["reset_after_seconds"] as? NSNumber).map { now.addingTimeInterval($0.doubleValue) }
            let exact = seconds != nil
            if selected[kind]?.exact != true || exact {
                selected[kind] = (AIQuotaWindow(kind: kind, usedPercent: used, resetsAt: reset), exact)
            }
        }
        let windows = [AIQuotaKind.session, .weekly].compactMap { selected[$0]?.window }
        guard !windows.isEmpty else { throw AIQuotaFailure.invalidResponse }
        return AIQuotaSnapshot(provider: .codex, windows: windows, fetchedAt: now)
    }
}

public actor ClaudeQuotaProvider: AIQuotaProvider {
    public nonisolated let id = AIProviderID.claude
    private let credentials: @Sendable () throws -> String
    private let http: any QuotaHTTPClient
    private let sub2api: (any Sub2APIQuotaFetching)?
    private let sub2apiConfiguration: @Sendable () async throws -> Sub2APIConfiguration?

    public init() {
        credentials = { try ClaudeQuotaCredentials.load() }
        http = URLSessionQuotaHTTPClient()
        sub2api = Sub2APIQuotaClient.shared
        sub2apiConfiguration = { try await Sub2APISettingsStore(provider: .claude).load() }
    }

    init(credentials: @escaping @Sendable () throws -> String, http: any QuotaHTTPClient,
         sub2api: (any Sub2APIQuotaFetching)? = nil,
         sub2apiConfiguration: @escaping @Sendable () async throws -> Sub2APIConfiguration? = { nil }) {
        self.credentials = credentials
        self.http = http
        self.sub2api = sub2api
        self.sub2apiConfiguration = sub2apiConfiguration
    }

    public func fetch() async throws -> AIQuotaSnapshot {
        do { return try await fetchDirect() }
        catch let directFailure as AIQuotaFailure {
            guard let sub2api else { throw directFailure }
            let configuration: Sub2APIConfiguration?
            do { configuration = try await sub2apiConfiguration() }
            catch { throw AIQuotaFailure.sub2apiConfiguration }
            guard let configuration else { throw directFailure }
            guard configuration.provider == .claude else { throw AIQuotaFailure.sub2apiConfiguration }
            return try await sub2api.fetch(configuration: configuration)
        }
    }

    private func fetchDirect() async throws -> AIQuotaSnapshot {
        let token = try credentials()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XStats AIUsage", forHTTPHeaderField: "User-Agent")
        let data = try await quotaResponse(for: request, using: http)
        return try Self.parse(data, now: Date())
    }

    static func parse(_ data: Data, now: Date) throws -> AIQuotaSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIQuotaFailure.invalidResponse
        }
        let fields: [(String, AIQuotaKind)] = [
            ("five_hour", .session), ("seven_day", .weekly),
            ("seven_day_opus", .opusWeekly), ("seven_day_sonnet", .sonnetWeekly),
        ]
        let formatter = ISO8601DateFormatter()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var windows: [AIQuotaWindow] = []
        for (field, kind) in fields {
            guard let item = object[field] as? [String: Any],
                  let used = (item["utilization"] as? NSNumber)?.doubleValue,
                  used.isFinite, (0...100).contains(used) else { continue }
            let reset = (item["resets_at"] as? String).flatMap { fractionalFormatter.date(from: $0) ?? formatter.date(from: $0) }
            windows.append(AIQuotaWindow(kind: kind, usedPercent: used, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw AIQuotaFailure.invalidResponse }
        return AIQuotaSnapshot(provider: .claude, windows: windows, fetchedAt: now)
    }
}

private func quotaResponse(for request: URLRequest, using http: any QuotaHTTPClient) async throws -> Data {
    let data: Data
    let status: Int
    do { (data, status) = try await http.send(request) }
    catch is CancellationError { throw CancellationError() }
    catch { throw AIQuotaFailure.network }
    switch status {
    case 200..<300: return data
    case 401, 403: throw AIQuotaFailure.unauthorized
    case 429: throw AIQuotaFailure.rateLimited
    default: throw AIQuotaFailure.network
    }
}
