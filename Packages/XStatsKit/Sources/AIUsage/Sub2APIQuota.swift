// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import LocalAuthentication
import Security

public enum Sub2APIConfigurationError: Error, Equatable {
    case invalidAddress, invalidAccountID, missingCredentials, providerMismatch, keychain(OSStatus)
}

public struct Sub2APIConfiguration: Equatable, Sendable {
    public let provider: AIProviderID
    public let baseURL: URL
    public let email: String
    public let password: String
    public let accountID: Int

    public init(address: String, email: String, password: String, accountID: String,
                provider: AIProviderID = .codex) throws {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmedAddress),
              parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw Sub2APIConfigurationError.invalidAddress
        }
        let prefix = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = prefix.isEmpty ? "" : "/" + prefix
        guard let baseURL = parts.url else { throw Sub2APIConfigurationError.invalidAddress }
        let trimmedAccount = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = Int(trimmedAccount), id > 0 else { throw Sub2APIConfigurationError.invalidAccountID }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else { throw Sub2APIConfigurationError.missingCredentials }
        self.provider = provider
        self.baseURL = baseURL
        self.email = trimmedEmail
        self.password = password
        self.accountID = id
    }

    func endpoint(_ path: String) -> URL { baseURL.appending(path: path) }
}

@MainActor
public protocol Sub2APISecretStore {
    func read() throws -> String?
    func write(_ password: String) throws
    func delete() throws
}

/// 管理员密码只保存在本机钥匙串；写入失败时不提交其余配置。
@MainActor
public struct KeychainSub2APISecretStore: Sub2APISecretStore {
    private let provider: AIProviderID

    public init(provider: AIProviderID = .codex) { self.provider = provider }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "work.12306.xstats.sub2api",
         kSecAttrAccount as String: provider == .codex ? "admin" : "admin.claude"]
    }

    public func read() throws -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        item[kSecUseAuthenticationContext as String] = context
        var result: AnyObject?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Sub2APIConfigurationError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Sub2APIConfigurationError.keychain(errSecDecode)
        }
        return value
    }

    public func write(_ password: String) throws {
        let data = Data(password.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "XStats Sub2API"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Sub2APIConfigurationError.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Sub2APIConfigurationError.keychain(status)
        }
    }
}

@MainActor
public struct Sub2APISettingsStore {
    private let provider: AIProviderID
    private let defaults: UserDefaults
    private let secrets: any Sub2APISecretStore
    private var key: String { provider == .codex ? "aiUsage.sub2api" : "aiUsage.sub2api.claude" }

    public init(provider: AIProviderID = .codex, defaults: UserDefaults = .standard,
                secrets: (any Sub2APISecretStore)? = nil) {
        self.provider = provider
        self.defaults = defaults
        self.secrets = secrets ?? KeychainSub2APISecretStore(provider: provider)
    }

    public func hasConfiguration() -> Bool { defaults.dictionary(forKey: key) != nil }

    public func load() throws -> Sub2APIConfiguration? {
        guard let saved = defaults.dictionary(forKey: key) else { return nil }
        guard let address = saved["address"] as? String,
              let email = saved["email"] as? String,
              let accountID = saved["accountID"] as? Int else {
            throw Sub2APIConfigurationError.missingCredentials
        }
        guard let password = try secrets.read() else { throw Sub2APIConfigurationError.missingCredentials }
        return try Sub2APIConfiguration(address: address, email: email,
                                        password: password, accountID: String(accountID), provider: provider)
    }

    public func save(_ configuration: Sub2APIConfiguration) throws {
        guard configuration.provider == provider else { throw Sub2APIConfigurationError.providerMismatch }
        try secrets.write(configuration.password)
        guard try secrets.read() == configuration.password else {
            throw Sub2APIConfigurationError.missingCredentials
        }
        defaults.set(["address": configuration.baseURL.absoluteString,
                      "email": configuration.email, "accountID": configuration.accountID], forKey: key)
    }

    public func clear() throws {
        try secrets.delete()
        defaults.removeObject(forKey: key)
    }
}

protocol Sub2APIQuotaFetching: Sendable {
    func fetch(configuration: Sub2APIConfiguration) async throws -> AIQuotaSnapshot
}

public actor Sub2APIQuotaClient: Sub2APIQuotaFetching {
    private struct AuthIdentity: Hashable {
        let baseURL: URL
        let email: String
        let password: String

        init(_ configuration: Sub2APIConfiguration) {
            baseURL = configuration.baseURL
            email = configuration.email
            password = configuration.password
        }
    }

    public static let shared = Sub2APIQuotaClient()
    private let http: any QuotaHTTPClient
    private var sessions: [AuthIdentity: (token: String, expiry: Date)] = [:]
    private var loginTasks: [AuthIdentity: Task<(String, Date), Error>] = [:]
    private var loginMarkers: [AuthIdentity: UUID] = [:]

    public init() { http = URLSessionQuotaHTTPClient() }

    init(http: any QuotaHTTPClient) { self.http = http }

    public func clearSession() {
        for task in loginTasks.values { task.cancel() }
        loginTasks.removeAll()
        loginMarkers.removeAll()
        sessions.removeAll()
    }

    public func fetch(configuration: Sub2APIConfiguration) async throws -> AIQuotaSnapshot {
        let token = try await validToken(configuration)
        let usageURL = configuration.endpoint("api/v1/admin/accounts/\(configuration.accountID)/usage")
        let accountURL = configuration.endpoint("api/v1/admin/accounts/\(configuration.accountID)")
        let accountData = try await get(accountURL, token: token, configuration: configuration)
        guard let account = Self.envelope(accountData),
              let platform = account["platform"] as? String else {
            throw AIQuotaFailure.sub2apiInvalidResponse
        }
        let expectedPlatform = configuration.provider == .codex ? "openai" : "anthropic"
        guard platform == expectedPlatform else { throw AIQuotaFailure.sub2apiAccountMismatch }
        var parts = URLComponents(url: usageURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "source", value: "active"),
                            URLQueryItem(name: "force", value: "false"),
                            URLQueryItem(name: "timezone", value: TimeZone.current.identifier)]
        do {
            let data = try await get(parts.url!, token: token, configuration: configuration)
            let snapshot = try Self.parseUsage(data, now: Date(), provider: configuration.provider)
            // Claude 的 Fable 周窗口可能只存在于账号 extra，详细接口缺失时回填。
            if configuration.provider == .claude, snapshot.window(.fableWeekly) == nil,
               let fallback = try? Self.parseAccount(accountData, now: Date(), provider: .claude),
               let extra = fallback.window(.fableWeekly) {
                return AIQuotaSnapshot(provider: .claude, windows: snapshot.windows + [extra],
                                       fetchedAt: snapshot.fetchedAt, source: .sub2api)
            }
            return snapshot
        } catch AIQuotaFailure.sub2apiInvalidResponse {
            // 较旧的 sub2api 没有 /usage 时，账号 extra 仍可提供较粗的窗口数据。
            return try Self.parseAccount(accountData, now: Date(), provider: configuration.provider)
        }
    }

    private func validToken(_ configuration: Sub2APIConfiguration) async throws -> String {
        let identity = AuthIdentity(configuration)
        if let session = sessions[identity], session.expiry > Date() { return session.token }
        if let task = loginTasks[identity] { return try await task.value.0 }
        let marker = UUID()
        let task = Task { try await login(configuration) }
        loginTasks[identity] = task
        loginMarkers[identity] = marker
        defer {
            if loginMarkers[identity] == marker {
                loginTasks[identity] = nil
                loginMarkers[identity] = nil
            }
        }
        let (token, expiry) = try await task.value
        if loginMarkers[identity] == marker { sessions[identity] = (token, expiry) }
        return token
    }

    private func login(_ configuration: Sub2APIConfiguration) async throws -> (String, Date) {
        var request = URLRequest(url: configuration.endpoint("api/v1/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": configuration.email,
                                                                       "password": configuration.password])
        let (data, status) = try await send(request)
        guard (200..<300).contains(status), let payload = Self.envelope(data),
              let token = payload["access_token"] as? String, !token.isEmpty else {
            throw AIQuotaFailure.sub2apiUnauthorized
        }
        let seconds = (payload["expires_in"] as? NSNumber)?.doubleValue ?? 600
        return (token, Date().addingTimeInterval(max(0, seconds - 60)))
    }

    private func get(_ url: URL, token: String, configuration: Sub2APIConfiguration) async throws -> Data {
        var token = token
        for attempt in 0...1 {
            var request = URLRequest(url: url)
            request.timeoutInterval = url.path.hasSuffix("/usage") ? 20 : 8
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, status) = try await send(request)
            if status == 401, attempt == 0 {
                sessions[AuthIdentity(configuration)] = nil
                token = try await validToken(configuration)
                continue
            }
            if status == 401 || status == 403 { throw AIQuotaFailure.sub2apiUnauthorized }
            if status == 404 { throw AIQuotaFailure.sub2apiInvalidResponse }
            guard (200..<300).contains(status) else { throw AIQuotaFailure.sub2apiNetwork }
            return data
        }
        throw AIQuotaFailure.sub2apiUnauthorized
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do { return try await http.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AIQuotaFailure.sub2apiNetwork }
    }

    private static func envelope(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["code"] as? NSNumber)?.intValue == 0 else { return nil }
        return object["data"] as? [String: Any]
    }

    static func parseUsage(_ data: Data, now: Date, provider: AIProviderID = .codex) throws -> AIQuotaSnapshot {
        guard let payload = envelope(data) else { throw AIQuotaFailure.sub2apiInvalidResponse }
        var windows: [AIQuotaWindow] = []
        var fields: [(String, AIQuotaKind)] = [("five_hour", .session), ("seven_day", .weekly)]
        if provider == .claude {
            fields += [("seven_day_sonnet", .sonnetWeekly), ("seven_day_fable", .fableWeekly)]
        }
        for (key, kind) in fields {
            guard let item = payload[key] as? [String: Any],
                  let used = (item["utilization"] as? NSNumber)?.doubleValue,
                  used.isFinite, (0...100).contains(used) else { continue }
            let reset = (item["resets_at"] as? String).flatMap(parseDate)
                ?? (item["remaining_seconds"] as? NSNumber).map { now.addingTimeInterval($0.doubleValue) }
            windows.append(AIQuotaWindow(kind: kind, usedPercent: used, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw AIQuotaFailure.sub2apiInvalidResponse }
        return AIQuotaSnapshot(provider: provider, windows: windows, fetchedAt: now, source: .sub2api)
    }

    static func parseAccount(_ data: Data, now: Date, provider: AIProviderID = .codex) throws -> AIQuotaSnapshot {
        guard let payload = envelope(data), let extra = payload["extra"] as? [String: Any] else {
            throw AIQuotaFailure.sub2apiInvalidResponse
        }
        var windows: [AIQuotaWindow] = []
        if let fraction = (extra["session_window_utilization"] as? NSNumber)?.doubleValue,
           fraction.isFinite, (0...1).contains(fraction) {
            windows.append(AIQuotaWindow(kind: .session, usedPercent: fraction * 100,
                resetsAt: (payload["session_window_end"] as? String).flatMap(parseDate)))
        }
        if let fraction = (extra["passive_usage_7d_utilization"] as? NSNumber)?.doubleValue,
           fraction.isFinite, (0...1).contains(fraction) {
            let reset = (extra["passive_usage_7d_reset"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(AIQuotaWindow(kind: .weekly, usedPercent: fraction * 100, resetsAt: reset))
        }
        if provider == .claude,
           let fraction = (extra["passive_usage_7d_oi_utilization"] as? NSNumber)?.doubleValue,
           fraction.isFinite, (0...1).contains(fraction) {
            let reset = (extra["passive_usage_7d_oi_reset"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(AIQuotaWindow(kind: .fableWeekly, usedPercent: fraction * 100, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw AIQuotaFailure.sub2apiInvalidResponse }
        return AIQuotaSnapshot(provider: provider, windows: windows, fetchedAt: now, source: .sub2api)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
