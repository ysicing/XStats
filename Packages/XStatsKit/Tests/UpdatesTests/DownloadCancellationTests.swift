// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Updates

struct DownloadCancellationTests {
    @Test func successfulDownloadMovesTemporaryFileAndRejectsHTTPFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadResponse-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadResponseProtocol.self]
        let destination = root.appendingPathComponent("update.zip")
        try await Downloader(destination: destination, progress: { _ in })
            .run(URL(string: "https://download.test/success")!, configuration: configuration)
        #expect(try Data(contentsOf: destination) == Data("verified payload".utf8))
        try FileManager.default.removeItem(at: destination)
        await #expect(throws: UpdateError.self) {
            try await Downloader(destination: destination, progress: { _ in })
                .run(URL(string: "https://download.test/failure")!, configuration: configuration)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancelledBeforeStartingDoesNotCreateASessionTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadCancellation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await UpdateInstaller.download(URL(string: "http://127.0.0.1:9/update.zip")!, into: root) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("update.zip").path))
    }

    @Test func cancellationRacingWithStartupAlwaysCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadStartup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<30 {
            let task = Task {
                try await UpdateInstaller.download(URL(string: "http://127.0.0.1:9/update.zip")!, into: root) { _ in }
            }
            await Task.yield()
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("已取消的下载不应成功")
            } catch is CancellationError {
            } catch let error as UpdateError {
                // 本机关闭端口可在取消送达前先返回连接错误。
                if case .download = error {} else { Issue.record("非预期错误：\(error)") }
            }
        }
    }
}

private final class DownloadResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: request.url!.path == "/success" ? 200 : 503,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "16"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("verified payload".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
