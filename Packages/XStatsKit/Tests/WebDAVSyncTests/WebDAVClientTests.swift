// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import WebDAVSync

private struct Transport: WebDAVTransport {
    let handler: @Sendable (URLRequest) async throws -> WebDAVResponse
    func send(_ request: URLRequest) async throws -> WebDAVResponse { try await handler(request) }
}

struct WebDAVClientTests {
    private func configuration() throws -> WebDAVConfiguration {
        try WebDAVConfiguration(address: "https://dav.example.com/dav/我的设置", username: "alice")
    }

    @Test func preservesDirectoryAndEncodesFilename() throws {
        let config = try configuration()
        #expect(config.fileURL.path == "/dav/我的设置/xstats-settings.json")
        #expect(config.fileURL.absoluteString.contains("%E6%88%91"))
        #expect(config.directoryURL.hasDirectoryPath)
        let slash = try WebDAVConfiguration(address: "https://dav.example.com/dav/我的设置/", username: "alice")
        #expect(config.credentialAccount == slash.credentialAccount)
        let other = try WebDAVConfiguration(address: "https://other.example.com/dav/", username: "alice")
        #expect(config.credentialAccount != other.credentialAccount)
    }

    @Test(arguments: [
        "http://dav.example.com/", "file:///tmp/", "https:///abc", "not-a-url",
        "https://user:secret@dav.example.com/", "https://dav.example.com/?token=secret",
        "https://dav.example.com/#fragment", "https://dav.example.com/a/../b/",
    ])
    func rejectsUnsafeAddresses(_ address: String) {
        #expect(throws: WebDAVError.invalidAddress) {
            try WebDAVConfiguration(address: address, username: "alice")
        }
    }

    @Test(arguments: ["", "user:name", "user\nname"])
    func rejectsInvalidUsername(_ username: String) {
        #expect(throws: WebDAVError.invalidUsername) {
            try WebDAVConfiguration(address: "https://dav.example.com/", username: username)
        }
    }

    @Test func downloadUsesAuthenticatedGET() async throws {
        let config = try configuration()
        let client = WebDAVClient(transport: Transport { request in
            #expect(request.url == config.fileURL)
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6c2VjcmV0")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return WebDAVResponse(data: Data("backup".utf8), status: 200)
        })
        let data = try await client.download(configuration: config, password: "secret")
        #expect(String(decoding: data, as: UTF8.self) == "backup")
    }

    @Test(arguments: [200, 201, 204])
    func uploadUsesPUTAndAcceptsCompletedSuccess(_ status: Int) async throws {
        let data = Data("settings".utf8)
        let client = WebDAVClient(transport: Transport { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.httpBody == data)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
            return WebDAVResponse(data: Data(), status: status)
        })
        try await client.upload(data, configuration: configuration(), password: "secret")
    }

    @Test(arguments: [401, 403, 404, 409, 413, 423, 500, 507, 302, 307, 202, 204])
    func rejectsUnsuccessfulDownload(_ status: Int) async throws {
        let client = WebDAVClient(transport: Transport { _ in WebDAVResponse(data: Data(), status: status) })
        await #expect(throws: WebDAVError.self) {
            try await client.download(configuration: configuration(), password: "secret")
        }
    }

    @Test func rejectsOversizedInputBeforeRequestAndOversizedResponse() async throws {
        let data = Data(repeating: 0, count: WebDAVClient.maximumBytes + 1)
        let client = WebDAVClient(transport: Transport { request in
            #expect(request.httpMethod == "GET", "Oversized uploads must not reach the transport")
            return WebDAVResponse(data: data, status: 200)
        })
        await #expect(throws: WebDAVError.tooLarge) {
            try await client.upload(data, configuration: configuration(), password: "secret")
        }
        await #expect(throws: WebDAVError.tooLarge) {
            try await client.download(configuration: configuration(), password: "secret")
        }
    }

    @Test func preservesCancellationAndSanitizesNetworkErrors() async throws {
        let cancel = WebDAVClient(transport: Transport { _ in throw URLError(.cancelled) })
        await #expect(throws: CancellationError.self) {
            try await cancel.download(configuration: configuration(), password: "secret")
        }
        let failed = WebDAVClient(transport: Transport { _ in
            throw NSError(domain: "secret-password", code: 1)
        })
        await #expect(throws: WebDAVError.transport) {
            try await failed.download(configuration: configuration(), password: "secret")
        }
    }

    @Test func emptyPasswordNeverSendsRequestAndUploadRequiresCompletion() async throws {
        let unused = WebDAVClient(transport: Transport { _ in
            Issue.record("A request with no password must not be sent")
            return WebDAVResponse(data: Data(), status: 200)
        })
        await #expect(throws: WebDAVError.missingPassword) {
            try await unused.download(configuration: configuration(), password: "")
        }
        let accepted = WebDAVClient(transport: Transport { _ in WebDAVResponse(data: Data(), status: 202) })
        await #expect(throws: WebDAVError.http(202)) {
            try await accepted.upload(Data(), configuration: configuration(), password: "secret")
        }
        let missing = WebDAVClient(transport: Transport { _ in WebDAVResponse(data: Data(), status: 404) })
        await #expect(throws: WebDAVError.directoryMissing) {
            try await missing.upload(Data(), configuration: configuration(), password: "secret")
        }
    }

    @Test func refusesRedirectsIncludingSameHost() async throws {
        let url = try #require(URL(string: "https://dav.example.com/"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url)
        let task = session.dataTask(with: request) // 不启动网络请求。
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
        let redirected = await RejectRedirects().urlSession(session, task: task,
            willPerformHTTPRedirection: response, newRequest: request)
        #expect(redirected == nil)
    }

    @Test(arguments: ["small", "large", "unauthorized"])
    func defaultTransportReadsBoundedResponses(_ scenario: String) async throws {
        let config = try WebDAVConfiguration(address: "https://xstats-webdav-transport.test/\(scenario)/", username: "alice")
        let client = WebDAVClient(transport: URLSessionWebDAVTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureProtocol.self]
            return configuration
        })
        switch scenario {
        case "large":
            await #expect(throws: WebDAVError.tooLarge) {
                try await client.download(configuration: config, password: "secret")
            }
        case "unauthorized":
            await #expect(throws: WebDAVError.unauthorized) {
                try await client.download(configuration: config, password: "secret")
            }
        default:
            let data = try await client.download(configuration: config, password: "secret")
            #expect(data == Data("fixture".utf8))
        }
    }
}

/// 只拦截本测试的保留域名；没有共享可变响应状态，不依赖外部服务器。
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "xstats-webdav-transport.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let unauthorized = url.path.contains("unauthorized")
        let data = url.path.contains("large")
            ? Data(repeating: 65, count: WebDAVClient.maximumBytes + 1) : Data("fixture".utf8)
        let response = HTTPURLResponse(url: url, statusCode: unauthorized ? 401 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
