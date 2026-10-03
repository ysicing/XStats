// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import os
import Testing
@testable import AIUsage

@Suite struct AICostReferenceTests {
    private static let date = Date(timeIntervalSince1970: 1_780_000_000)
    private static let prices = Data(#"{"openai":{"models":{"gpt-test":{"cost":{"input":2,"output":8,"cache_read":0.5}}}},"anthropic":{"models":{"claude-test":{"cost":{"input":3,"output":15,"cache_read":0.3,"cache_write":3.75}}}}}"#.utf8)
    private static let exchange = Data(#"{"result":"success","base_code":"USD","rates":{"CNY":7.25}}"#.utf8)

    private func row(_ model: String = "claude-test", input: Int = 0, cached: Int = 0,
                     output: Int = 0, created: Int = 0) -> ModelTokenUsage {
        ModelTokenUsage(day: Self.date, model: model, input: input, cached: cached, output: output, cacheCreated: created)
    }

    @Test func cacheTokensAreChargedExactlyOnce() throws {
        let catalog = try AIPriceCatalog.parse(Self.prices, fetchedAt: Self.date)
        let result = catalog.estimate([row(input: 1_000_000, cached: 200_000, output: 100_000, created: 100_000)])
        let usd = try #require(result.usd)
        // 700k 普通输入 + 200k 读取 + 100k 创建 + 100k 输出。
        #expect(abs(usd - 4.035) < 0.0000001)
        #expect(result.unpricedModels.isEmpty)
    }

    @Test func missingUsedCategoryMakesRowUnknownButExplicitZeroIsFree() throws {
        let catalog = AIPriceCatalog(prices: [
            "missing": AIModelPrice(input: 1, output: 2),
            "free": AIModelPrice(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        ], fetchedAt: Self.date)
        #expect(catalog.estimate([row("missing", input: 10, cached: 1)]).usd == nil)
        #expect(catalog.estimate([row("missing", input: 10, created: 1)]).usd == nil)
        #expect(catalog.estimate([row("missing", input: 10)]).usd == 0.00001)
        #expect(catalog.estimate([row("free", input: 10, cached: 3, output: 4, created: 2)]).usd == 0)
    }

    @Test func unknownModelsRemainVisibleAndOnlyExplicitPrefixesMatch() throws {
        let catalog = try AIPriceCatalog.parse(Self.prices, fetchedAt: Self.date)
        let result = catalog.estimate([
            row("openai/gpt-test", input: 1_000_000), row("anthropic/claude-test", output: 1_000_000),
            row("gpt-test-new", input: 2), row("other/gpt-test", input: 2),
            row("openai/claude-test", input: 2), row("gpt-test-new", input: 2),
            row("claude-test-20991231", input: 2)
        ])
        #expect(result.usd == 17)
        #expect(result.unpricedModels == ["claude-test-20991231", "gpt-test-new", "openai/claude-test", "other/gpt-test"])
        #expect(catalog.estimate([row("unknown", input: 1)]).usd == nil)
        #expect(catalog.estimate([]).usd == 0)
        #expect(catalog.estimate([row("unknown")]).usd == 0)
    }

    @Test func invalidCountsAndOverflowNeverProduceNonfiniteCost() {
        let catalog = AIPriceCatalog(prices: ["a": AIModelPrice(input: .greatestFiniteMagnitude, output: 1)], fetchedAt: Self.date)
        for value in [row("a", input: -1), row("a", input: 1, cached: 2), row("a", input: 2, cached: 1, created: 2),
                      row("a", input: .max), row("a", input: 1, cached: .max, created: .max)] {
            #expect(catalog.estimate([value]).usd == nil)
        }
        let large = catalog.estimate([row("a", input: 1_000_000), row("a", input: 1_000_000)])
        #expect(large.usd?.isFinite == true)
        #expect(large.unpricedModels == ["a"])
        for value in [Double.infinity, .nan, -1] {
            let invalid = AIPriceCatalog(prices: ["a": AIModelPrice(input: value, output: 1)], fetchedAt: Self.date)
            #expect(invalid.estimate([row("a", input: 1)]).usd == nil)
        }
    }

    @Test func parsingRejectsMalformedPricesAndIgnoresOtherProviders() throws {
        let data = Data(#"{"openai":{"models":{"missing":{"cost":{"input":1}},"negative":{"cost":{"input":-1,"output":1}},"boolean":{"cost":{"input":true,"output":2}},"string":{"cost":{"input":"2","output":2}},"free":{"cost":{"input":0,"output":0}},"bad-cache":{"cost":{"input":1,"output":1,"cache_read":false,"cache_write":-2}}}},"reseller":{"models":{"private":{"cost":{"input":1,"output":1}}}}}"#.utf8)
        let result = try AIPriceCatalog.parse(data, fetchedAt: Self.date)
        #expect(Set(result.prices.keys) == ["free", "bad-cache"])
        #expect(result.prices["bad-cache"]?.cacheRead == nil)
        #expect(result.prices["bad-cache"]?.cacheWrite == nil)
        #expect(result.estimate([row("bad-cache", input: 1, cached: 1)]).usd == nil)
        #expect(throws: AICostReferenceError.invalidResponse) {
            try AIPriceCatalog.parse(Data(#"{"openai":{"models":{}}}"#.utf8), fetchedAt: Self.date)
        }
    }

    @Test func exchangeRateRequiresUSDAndPositiveNumericCNY() throws {
        #expect(try AIExchangeRate.parse(Self.exchange, fetchedAt: Self.date).cnyPerUSD == 7.25)
        for json in [#"{"result":"error","base_code":"USD","rates":{"CNY":7}}"#,
                     #"{"result":"success","base_code":"EUR","rates":{"CNY":7}}"#,
                     #"{"result":"success","base_code":"USD","rates":{"CNY":0}}"#,
                     #"{"result":"success","base_code":"USD","rates":{"CNY":-1}}"#,
                     #"{"result":"success","base_code":"USD","rates":{"CNY":true}}"#,
                     #"{"result":"success","base_code":"USD","rates":{"CNY":"7"}}"#,
                     #"{"result":"success","base_code":"USD","rates":{}}"#] {
            #expect(throws: AICostReferenceError.invalidResponse) {
                try AIExchangeRate.parse(Data(json.utf8), fetchedAt: Self.date)
            }
        }
    }

    @Test func limitsRejectOversizedInjectedResponses() async {
        let store = AICostReferenceStore(cacheDirectory: nil, fetch: { _, limit in Data(repeating: 32, count: limit + 1) })
        let result = await store.refresh(needsExchangeRate: true)
        #expect(result.catalog == nil)
        #expect(result.exchangeRate == nil)
    }

    @Test func refreshHonorsIndependentTTLsAndOnDemandExchange() async {
        let clock = OSAllocatedUnfairLock(initialState: Self.date)
        let server = ReferenceServer()
        let store = AICostReferenceStore(cacheDirectory: nil, now: { clock.withLock { $0 } }, fetch: server.fetch)
        #expect(await store.refresh(needsExchangeRate: false).catalog != nil)
        #expect(await server.counts == [1, 0])
        #expect(await store.refresh(needsExchangeRate: true).exchangeRate != nil)
        #expect(await server.counts == [1, 1])
        clock.withLock { $0 = $0.addingTimeInterval(43_200) }
        _ = await store.refresh(needsExchangeRate: false)
        #expect(await server.counts == [1, 1])
        _ = await store.refresh(needsExchangeRate: true)
        #expect(await server.counts == [1, 2])
        clock.withLock { $0 = $0.addingTimeInterval(43_200) }
        _ = await store.refresh(needsExchangeRate: true)
        #expect(await server.counts == [2, 3])
    }

    @Test func failureKeepsOldCacheAndBacksOffTenMinutes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = OSAllocatedUnfairLock(initialState: Self.date)
        let server = ReferenceServer()
        let store = AICostReferenceStore(cacheDirectory: root, now: { clock.withLock { $0 } }, fetch: server.fetch)
        let original = await store.refresh(needsExchangeRate: true)
        clock.withLock { $0 = $0.addingTimeInterval(86_400) }
        await server.setFailure(true)
        #expect(await store.refresh(needsExchangeRate: true) == original)
        #expect(await server.counts == [2, 2])
        clock.withLock { $0 = $0.addingTimeInterval(599) }
        #expect(await store.refresh(needsExchangeRate: true) == original)
        #expect(await server.counts == [2, 2])
        clock.withLock { $0 = $0.addingTimeInterval(1) }
        #expect(await store.refresh(needsExchangeRate: true) == original)
        #expect(await server.counts == [3, 3])
        let restarted = AICostReferenceStore(cacheDirectory: root, now: { clock.withLock { $0 } }, fetch: server.fetch)
        #expect(await restarted.refresh(needsExchangeRate: true) == original)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(files == ["exchange-v1.json", "prices-v1.json"])
        #expect(try Data(contentsOf: root.appendingPathComponent("prices-v1.json")).count < 10_000)
    }

    @Test func freshDiskCacheAvoidsNetworkAndInvalidCacheIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = ReferenceServer()
        let first = AICostReferenceStore(cacheDirectory: root, now: { Self.date }, fetch: server.fetch)
        let original = await first.refresh(needsExchangeRate: true)
        let second = AICostReferenceStore(cacheDirectory: root, now: { Self.date }, fetch: server.fetch)
        #expect(await second.refresh(needsExchangeRate: true) == original)
        #expect(await server.counts == [1, 1])
        try Data(repeating: 32, count: 1024 * 1024 + 1).write(to: root.appendingPathComponent("prices-v1.json"))
        let invalid = AIExchangeRate(cnyPerUSD: -1, fetchedAt: Self.date)
        try JSONEncoder().encode(invalid).write(to: root.appendingPathComponent("exchange-v1.json"))
        await server.setFailure(true)
        let third = AICostReferenceStore(cacheDirectory: root, now: { Self.date }, fetch: server.fetch)
        let result = await third.refresh(needsExchangeRate: true)
        #expect(result.catalog == nil)
        #expect(result.exchangeRate == nil)
    }

    @Test func coldFailureReturnsNilAndRetriesOnlyAfterBackoff() async {
        let server = ReferenceServer()
        await server.setFailure(true)
        let store = AICostReferenceStore(cacheDirectory: nil, now: { Self.date }, fetch: server.fetch)
        let first = await store.refresh(needsExchangeRate: true)
        #expect(first.catalog == nil && first.exchangeRate == nil)
        _ = await store.refresh(needsExchangeRate: true)
        #expect(await server.counts == [1, 1])
    }

    @Test func concurrentRequestsMergeAndLateExchangeDemandIsFulfilled() async {
        let server = ReferenceServer(suspended: true)
        let store = AICostReferenceStore(cacheDirectory: nil, now: { Self.date }, fetch: server.fetch)
        let dollars = Task { await store.refresh(needsExchangeRate: false) }
        await server.waitForRequest()
        let yuan = Task { await store.refresh(needsExchangeRate: true) }
        let moreDollars = Task { await store.refresh(needsExchangeRate: false) }
        await server.release()
        #expect(await dollars.value.catalog != nil)
        #expect(await moreDollars.value.catalog != nil)
        #expect(await yuan.value.exchangeRate != nil)
        #expect(await server.counts == [1, 1])
    }

    @Test func cancellationDoesNotPublishOrPersistAndNextRefreshCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = ReferenceServer(suspended: true)
        let store = AICostReferenceStore(cacheDirectory: root, now: { Self.date }, fetch: server.fetch)
        let task = Task { await store.refresh(needsExchangeRate: true) }
        await server.waitForRequest()
        task.cancel()
        await server.release()
        let canceled = await task.value
        #expect(canceled.catalog == nil && canceled.exchangeRate == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(await server.counts == [1, 0])
        let next = await store.refresh(needsExchangeRate: true)
        #expect(next.catalog != nil && next.exchangeRate != nil)
        #expect(await server.counts == [2, 1])
    }

    private actor ReferenceServer {
        private var fail = false
        private var suspended: Bool
        private var pending: [CheckedContinuation<Void, Never>] = []
        private var observers: [CheckedContinuation<Void, Never>] = []
        private(set) var counts = [0, 0]
        init(suspended: Bool = false) { self.suspended = suspended }
        func setFailure(_ value: Bool) { fail = value }
        func waitForRequest() async {
            if counts.reduce(0, +) > 0 { return }
            await withCheckedContinuation { observers.append($0) }
        }
        func release() {
            suspended = false
            let waiting = pending; pending.removeAll()
            waiting.forEach { $0.resume() }
        }
        func fetch(_ url: URL, limit: Int) async throws -> Data {
            let isCatalog = url.host == "models.dev"
            #expect(url.absoluteString == (isCatalog ? "https://models.dev/api.json" : "https://open.er-api.com/v6/latest/USD"))
            #expect(limit == (isCatalog ? 16 * 1024 * 1024 : 1024 * 1024))
            counts[isCatalog ? 0 : 1] += 1
            let waiting = observers; observers.removeAll()
            waiting.forEach { $0.resume() }
            if suspended { await withCheckedContinuation { pending.append($0) } }
            if fail { throw URLError(.notConnectedToInternet) }
            return isCatalog ? AICostReferenceTests.prices : AICostReferenceTests.exchange
        }
    }
}
