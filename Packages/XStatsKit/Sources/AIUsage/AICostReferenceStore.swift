// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 按需获取公开参考数据，无定时器；磁盘仅保存两个有界的参考数据文件。
public actor AICostReferenceStore {
    public static let shared = AICostReferenceStore()
    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XStats/AIReference", isDirectory: true)
    }
    static let catalogLimit = 16 * 1024 * 1024
    static let exchangeLimit = 1024 * 1024
    private static let cacheLimit = 1024 * 1024
    private static let retryDelay: TimeInterval = 600
    private let cacheDirectory: URL?
    private let now: @Sendable () -> Date
    private let fetch: @Sendable (URL, Int) async throws -> Data
    private var loaded = false
    private var catalog: AIPriceCatalog?
    private var exchangeRate: AIExchangeRate?
    private var catalogRetryAt: Date?
    private var exchangeRetryAt: Date?
    private var flight: Flight?

    private struct Flight {
        let id: UUID
        let task: Task<RefreshResult, Never>
        var waiters: Set<UUID>
    }
    private struct RefreshResult: Sendable {
        var catalog: AIPriceCatalog?
        var exchangeRate: AIExchangeRate?
        var catalogFailed = false
        var exchangeFailed = false
    }

    /// nil 缓存目录用于无持久化环境。fetch/now 只用于注入可重复测试依赖。
    public init(cacheDirectory: URL? = AICostReferenceStore.defaultCacheDirectory,
                now: @escaping @Sendable () -> Date = { Date() },
                fetch: (@Sendable (URL, Int) async throws -> Data)? = nil) {
        self.cacheDirectory = cacheDirectory; self.now = now
        self.fetch = fetch ?? Self.download
    }

    /// 失败继续返回已有缓存；并发需求合并，最后一个等待者取消时终止请求。
    /// 只有未取消的等待者可提交结果；美元需求不会主动请求汇率。
    public func refresh(needsExchangeRate: Bool) async -> AICostReferenceSnapshot {
        guard !Task.isCancelled else { return snapshot }
        loadCache()
        let waiter = UUID()
        while !Task.isCancelled {
            let date = now()
            let needsCatalog = needsRefresh(catalog?.fetchedAt, ttl: 86_400, retryAt: catalogRetryAt, now: date)
            let needsExchange = needsExchangeRate
                && needsRefresh(exchangeRate?.fetchedAt, ttl: 43_200, retryAt: exchangeRetryAt, now: date)
            guard needsCatalog || needsExchange else { return snapshot }
            let current: Flight
            if var existing = flight {
                existing.waiters.insert(waiter); flight = existing; current = existing
            } else {
                let task = Task { await self.fetchReferences(catalog: needsCatalog, exchange: needsExchange) }
                current = Flight(id: UUID(), task: task, waiters: [waiter]); flight = current
            }
            let result = await withTaskCancellationHandler {
                await current.task.value
            } onCancel: {
                Task { await self.cancelWaiter(waiter, flightID: current.id) }
            }
            guard !Task.isCancelled else {
                cancelWaiter(waiter, flightID: current.id)
                return snapshot
            }
            // 其他等待者可能已经提交结果或取消了整轮；旧轮次不能覆盖新状态。
            if flight?.id == current.id {
                flight = nil
                guard !current.task.isCancelled else { continue }
                let finished = now()
                if let value = result.catalog {
                    catalog = value; catalogRetryAt = nil; save(value, name: "prices-v1.json")
                } else if result.catalogFailed {
                    catalogRetryAt = finished.addingTimeInterval(Self.retryDelay)
                }
                if let value = result.exchangeRate {
                    exchangeRate = value; exchangeRetryAt = nil; save(value, name: "exchange-v1.json")
                } else if result.exchangeFailed {
                    exchangeRetryAt = finished.addingTimeInterval(Self.retryDelay)
                }
            }
            // 若人民币调用加入了只获取价格的轮次，价格提交后再按需补一次汇率。
        }
        return snapshot
    }

    private var snapshot: AICostReferenceSnapshot {
        AICostReferenceSnapshot(catalog: catalog, exchangeRate: exchangeRate)
    }

    private func cancelWaiter(_ waiter: UUID, flightID: UUID) {
        guard var current = flight, current.id == flightID else { return }
        current.waiters.remove(waiter)
        if current.waiters.isEmpty { current.task.cancel(); flight = nil } else { flight = current }
    }

    private func needsRefresh(_ fetchedAt: Date?, ttl: TimeInterval, retryAt: Date?, now: Date) -> Bool {
        if let retryAt, now < retryAt { return false }
        guard let fetchedAt else { return true }
        let age = now.timeIntervalSince(fetchedAt)
        return age < 0 || age >= ttl
    }

    private func fetchReferences(catalog needsCatalog: Bool, exchange needsExchange: Bool) async -> RefreshResult {
        var result = RefreshResult()
        if needsCatalog {
            do {
                try Task.checkCancellation()
                let data = try await fetch(URL(string: "https://models.dev/api.json")!, Self.catalogLimit)
                try Task.checkCancellation()
                result.catalog = try AIPriceCatalog.parse(data, fetchedAt: now())
            } catch {
                result.catalogFailed = !Task.isCancelled
            }
        }
        if needsExchange && !Task.isCancelled {
            do {
                let data = try await fetch(URL(string: "https://open.er-api.com/v6/latest/USD")!, Self.exchangeLimit)
                try Task.checkCancellation()
                result.exchangeRate = try AIExchangeRate.parse(data, fetchedAt: now())
            } catch {
                result.exchangeFailed = !Task.isCancelled
            }
        }
        return result
    }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        if let value: AIPriceCatalog = read(name: "prices-v1.json"),
           value.fetchedAt.timeIntervalSince1970.isFinite, !value.prices.isEmpty,
           value.prices.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.isValid }) {
            catalog = value
        }
        if let value: AIExchangeRate = read(name: "exchange-v1.json"),
           value.fetchedAt.timeIntervalSince1970.isFinite, value.cnyPerUSD.isFinite, value.cnyPerUSD > 0 {
            exchangeRate = value
        }
    }

    private func read<Value: Decodable>(name: String) -> Value? {
        guard let url = cacheDirectory?.appendingPathComponent(name),
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        // 有界读取也防止磁盘缓存被意外替换为大型文件。
        guard let data = try? file.read(upToCount: Self.cacheLimit + 1), data.count <= Self.cacheLimit else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func save(_ value: some Encodable, name: String) {
        guard !Task.isCancelled, let cacheDirectory,
              let data = try? JSONEncoder().encode(value), data.count <= Self.cacheLimit else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: cacheDirectory.appendingPathComponent(name), options: .atomic)
        } catch {
            // 缓存写入失败不使已验证的公开参考数据失效，下一次启动重新获取。
        }
    }

    private static func download(_ url: URL, limit: Int) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AICostReferenceError.invalidResponse
        }
        guard response.expectedContentLength <= Int64(limit) else { throw AICostReferenceError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw AICostReferenceError.responseTooLarge }
            data.append(byte)
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return data
    }
}
