// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// URLSession 的 delegate/取消可能来自不同队列；锁保护结果、缓冲与 continuation，完成恰好一次。
private final class GeographyDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private let host: String?
    private let progress: @Sendable (Double) -> Void
    private var data = Data()
    private var result: Result<Data, any Error>?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var task: URLSessionDataTask?
    private var lastStep = -1

    init(maximum: Int, host: String?, progress: @escaping @Sendable (Double) -> Void) {
        self.maximum = maximum; self.host = host; self.progress = progress
    }

    static func fetch(_ url: URL, maximum: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let delegate = GeographyDownload(maximum: maximum, host: url.host, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let task = session.dataTask(with: request)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.install(continuation, task: task)
                task.resume()
            }
        } onCancel: { delegate.finish(.failure(CancellationError())) }
    }

    private func install(_ continuation: CheckedContinuation<Data, any Error>, task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let previous = result
        if previous == nil { self.continuation = continuation }
        lock.unlock()
        if let previous { task.cancel(); continuation.resume(with: previous) }
    }

    private func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation, task = task
        self.continuation = nil; self.task = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == host,
              response.expectedContentLength <= Int64(maximum) else {
            finish(.failure(URLError(.badServerResponse))); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // 数据只来自约定的 HTTPS CDN；不跟随到任意主机或明文地址。
        if request.url?.scheme == "https", request.url?.host == host { completionHandler(request) }
        else { finish(.failure(URLError(.badServerResponse))); completionHandler(nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        guard data.count + chunk.count <= maximum else {
            lock.unlock(); finish(.failure(URLError(.dataLengthExceedsMaximum))); return
        }
        data.append(chunk)
        let fraction = Double(data.count) / Double(maximum)
        let step = Int(fraction * 20)
        let publish = step > lastStep
        if publish { lastStep = step }
        lock.unlock()
        if publish { progress(fraction) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let complete = data; lock.unlock()
        finish(.success(complete))
    }
}

func downloadGeography(_ url: URL, maximum: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
    try await GeographyDownload.fetch(url, maximum: maximum, progress: progress)
}
