// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Localization

public enum WebDAVError: Error, LocalizedError, Equatable, Sendable {
    case invalidAddress, invalidUsername, missingPassword, notConfigured
    case unauthorized, forbidden, notFound, directoryMissing, locked, insufficientStorage
    case redirect, tooLarge, invalidDocument, unsupportedVersion, transport
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: tr("请输入有效的 HTTPS WebDAV 目录地址，不要包含账号、查询参数或片段")
        case .invalidUsername: tr("请输入 WebDAV 用户名，不能包含冒号或控制字符")
        case .missingPassword: tr("请输入 WebDAV 密码或应用专用密码")
        case .notConfigured: tr("请先保存 WebDAV 配置")
        case .unauthorized: tr("WebDAV 认证失败，请检查用户名和密码")
        case .forbidden: tr("WebDAV 拒绝访问，请检查目录读写权限")
        case .notFound: tr("远端尚无设置文件，请先上传本机设置")
        case .directoryMissing: tr("WebDAV 目录不存在，请先在服务器上创建该目录")
        case .locked: tr("远端文件已锁定，请稍后重试")
        case .insufficientStorage: tr("WebDAV 存储空间不足")
        case .redirect: tr("WebDAV 地址发生重定向，请填写最终目录地址")
        case .tooLarge: tr("设置文件超过 1 MB，已停止同步")
        case .invalidDocument: tr("远端文件不是有效的 XStats 设置备份，本机设置未更改")
        case .unsupportedVersion: tr("设置备份版本不受支持，请先更新 XStats")
        case .transport: tr("无法连接 WebDAV，请检查网络、地址和 HTTPS 证书")
        case .http(let status): tr("WebDAV 返回错误：\(status)")
        }
    }
}

/// 只保存非敏感连接信息。目录必须已存在，固定文件名避免用户误覆盖其他文件。
public struct WebDAVConfiguration: Equatable, Sendable {
    public let directoryURL: URL
    public let username: String
    public var fileURL: URL { directoryURL.appendingPathComponent("xstats-settings.json") }

    public init(address: String, username: String) throws {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let url = components.url else { throw WebDAVError.invalidAddress }
        guard !username.isEmpty, !username.contains(":"),
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw WebDAVError.invalidUsername }
        directoryURL = url.hasDirectoryPath ? url : url.appendingPathComponent("", isDirectory: true)
        self.username = username
    }

    /// 密码按端点和用户隔离，更换服务器时不会向新服务器发送旧密码。
    public var credentialAccount: String {
        SHA256.hash(data: Data("\(fileURL.absoluteString)\n\(username)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public struct WebDAVResponse: Sendable {
    public let data: Data
    public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status }
}

public protocol WebDAVTransport: Sendable {
    func send(_ request: URLRequest) async throws -> WebDAVResponse
}

/// 独立的临时会话不共享 Cookie 或凭据；流式读取限制内存占用，并拒绝带认证信息重定向。
public struct URLSessionWebDAVTransport: WebDAVTransport {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        makeConfiguration = configuration
    }

    public func send(_ request: URLRequest) async throws -> WebDAVResponse {
        let configuration = makeConfiguration()
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: RejectRedirects())
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.transport }
        // 非 GET 成功响应无需读取内容，避免错误 HTML 或 PUT 响应体影响结果。
        guard request.httpMethod == "GET", http.statusCode == 200 else {
            return WebDAVResponse(data: Data(), status: http.statusCode)
        }
        guard response.expectedContentLength <= Int64(WebDAVClient.maximumBytes) else { throw WebDAVError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < WebDAVClient.maximumBytes else { throw WebDAVError.tooLarge }
            data.append(byte)
        }
        return WebDAVResponse(data: data, status: http.statusCode)
    }
}

/// 一律拒绝重定向，避免 Basic 密码泄漏或 PUT 被服务端重定向改成 GET。
final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// GET 下载、PUT 整份上传；用户在界面确认覆盖，不做隐式后台合并或自动重试上传。
public struct WebDAVClient: Sendable {
    public static let maximumBytes = 1_048_576
    private let transport: any WebDAVTransport

    public init(transport: any WebDAVTransport = URLSessionWebDAVTransport()) { self.transport = transport }

    public func download(configuration: WebDAVConfiguration, password: String) async throws -> Data {
        let response = try await perform("GET", configuration: configuration, password: password)
        guard response.status == 200 else { throw failure(response.status, uploading: false) }
        guard response.data.count <= Self.maximumBytes else { throw WebDAVError.tooLarge }
        return response.data
    }

    public func upload(_ data: Data, configuration: WebDAVConfiguration, password: String) async throws {
        guard data.count <= Self.maximumBytes else { throw WebDAVError.tooLarge }
        let response = try await perform("PUT", configuration: configuration, password: password, data: data)
        guard [200, 201, 204].contains(response.status) else { throw failure(response.status, uploading: true) }
    }

    private func perform(_ method: String, configuration: WebDAVConfiguration, password: String,
                         data: Data? = nil) async throws -> WebDAVResponse {
        try Task.checkCancellation()
        guard !password.isEmpty else { throw WebDAVError.missingPassword }
        var request = URLRequest(url: configuration.fileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Basic " + Data("\(configuration.username):\(password)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XStats", forHTTPHeaderField: "User-Agent")
        if let data {
            request.httpBody = data
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        do {
            let response = try await transport.send(request)
            try Task.checkCancellation()
            return response
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // 不展示服务端原始错误体或 URL 错误信息，防止返回内容包含凭据。
            throw error as? WebDAVError ?? WebDAVError.transport
        }
    }

    private func failure(_ status: Int, uploading: Bool) -> WebDAVError {
        switch status {
        case 301...399: .redirect
        case 401: .unauthorized
        case 403: .forbidden
        case 404: uploading ? .directoryMissing : .notFound
        case 409: .directoryMissing
        case 413: .tooLarge
        case 423: .locked
        case 507: .insufficientStorage
        default: .http(status)
        }
    }
}
