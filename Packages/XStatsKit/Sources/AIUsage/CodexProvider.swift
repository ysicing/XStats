// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum AIHTTPMethod: String, Sendable {
    case get = "GET"
}

struct AIHTTPRequest: Sendable {
    let method: AIHTTPMethod
    let url: URL
    var headers: [String: String] = [:]
    var body: Data?
}

struct AIHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

protocol AIHTTPClient: Sendable {
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse
}

private actor URLSessionAIHTTPClient: AIHTTPClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: RejectQuotaRedirects(), delegateQueue: nil)
    }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        var value = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        value.httpMethod = request.method.rawValue
        value.httpBody = request.body
        for (name, header) in request.headers { value.setValue(header, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: value)
        guard let response = response as? HTTPURLResponse else { throw AIUsageFailure.network }
        let headers = Dictionary(uniqueKeysWithValues: response.allHeaderFields.compactMap { key, value in
            (key as? String).map { ($0, String(describing: value)) }
        })
        return AIHTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
    }
}

/// 配额凭据只能发往固定端点，任何重定向都交回调用方按错误处理。
private final class RejectQuotaRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

public protocol AIUsageProvider: Sendable {
    var id: AIProviderID { get }
    func fetch() async throws -> AIUsageSnapshot
}

public actor CodexProvider: AIUsageProvider {
    public nonisolated let id = AIProviderID.codex

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let credentials: @Sendable () throws -> CodexCredentials
    private let http: any AIHTTPClient
    private let now: @Sendable () -> Date

    public init() {
        credentials = { try CodexCredentialStore.load() }
        http = URLSessionAIHTTPClient()
        now = Date.init
    }

    init(credentials: @escaping @Sendable () throws -> CodexCredentials,
         http: any AIHTTPClient,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials
        self.http = http
        self.now = now
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let credentials = try credentials()
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
            "User-Agent": "XStats AIUsage",
        ]
        if let accountID = credentials.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let response: AIHTTPResponse
        do {
            response = try await http.send(AIHTTPRequest(method: .get, url: Self.usageURL, headers: headers))
        } catch let failure as AIUsageFailure {
            throw failure
        } catch {
            throw AIUsageFailure.network
        }

        switch response.statusCode {
        case 200..<300:
            return try CodexUsageMapper.map(data: response.body, headers: response.headers, now: now())
        case 401, 403:
            throw AIUsageFailure.unauthorized
        case 429:
            throw AIUsageFailure.rateLimited(Self.retryDate(response.header("Retry-After"), now: now()))
        case 500...:
            throw AIUsageFailure.server(response.statusCode)
        default:
            throw AIUsageFailure.invalidResponse
        }
    }

    private static func retryDate(_ raw: String?, now: Date) -> Date {
        if let seconds = raw.flatMap(Double.init), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        if let raw {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: raw) { return date }
        }
        return now.addingTimeInterval(5 * 60)
    }
}
