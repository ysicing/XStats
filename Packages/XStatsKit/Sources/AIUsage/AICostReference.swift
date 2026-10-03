// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CoreFoundation

/// 公开 API 的基础美元单价，单位为每百万 Token；不是订阅账单。
public struct AIModelPrice: Codable, Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double?
    public let cacheWrite: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }

    var isValid: Bool {
        [input, output].allSatisfy { $0.isFinite && $0 >= 0 }
            && [cacheRead, cacheWrite].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
    }
}

public struct AICostEstimate: Equatable, Sendable {
    public let usd: Double?
    public let unpricedModels: [String]

    public init(usd: Double?, unpricedModels: [String]) {
        self.usd = usd; self.unpricedModels = unpricedModels
    }
}

public struct AIPriceCatalog: Codable, Equatable, Sendable {
    public let prices: [String: AIModelPrice]
    public let fetchedAt: Date

    public init(prices: [String: AIModelPrice], fetchedAt: Date) {
        self.prices = prices; self.fetchedAt = fetchedAt
    }

    /// 本地输入包含缓存读取和创建；输出已包含推理 Token，不能再次叠加。
    /// 仅采用目录中的基础费率，不推测逐请求上下文阶梯、缓存时长或订阅折扣。
    public func estimate(_ rows: [ModelTokenUsage]) -> AICostEstimate {
        var total = 0.0
        var priced = rows.isEmpty
        var unknown = Set<String>()
        for row in rows {
            guard row.input >= 0, row.cached >= 0, row.cacheCreated >= 0, row.output >= 0,
                  row.cached <= row.input, row.cacheCreated <= row.input - row.cached else {
                unknown.insert(row.model); continue
            }
            if row.input == 0 && row.output == 0 { priced = true; continue }
            var model = row.model
            // 只去掉明确的厂商命名空间；不剥离日期、版本或任意后缀。
            if model.hasPrefix("openai/"), !model.dropFirst(7).hasPrefix("claude-") {
                model = String(model.dropFirst(7))
            } else if model.hasPrefix("anthropic/"), model.dropFirst(10).hasPrefix("claude-") {
                model = String(model.dropFirst(10))
            }
            guard let price = prices[row.model] ?? prices[model], price.isValid else {
                unknown.insert(row.model); continue
            }
            let categories: [(Int, Double?)] = [
                (row.input - row.cached - row.cacheCreated, price.input),
                (row.cached, price.cacheRead), (row.cacheCreated, price.cacheWrite), (row.output, price.output)
            ]
            var amount = 0.0
            var complete = true
            for (tokens, rate) in categories where tokens > 0 {
                guard let rate else { complete = false; break }
                // 先缩放，避免合法大 Token 数与单价的中间乘积溢出。
                amount += (Double(tokens) / 1_000_000) * rate
            }
            guard complete, amount.isFinite, (total + amount).isFinite else {
                unknown.insert(row.model); continue
            }
            total += amount; priced = true
        }
        return AICostEstimate(usd: priced ? total : nil, unpricedModels: unknown.sorted())
    }

    /// models.dev 的 cost 为美元/百万 Token。忽略第三方转售商和缺失必需单价的模型。
    static func parse(_ data: Data, fetchedAt: Date) throws -> Self {
        guard data.count <= AICostReferenceStore.catalogLimit,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AICostReferenceError.invalidResponse
        }
        var prices: [String: AIModelPrice] = [:]
        for provider in ["openai", "anthropic"] {
            guard let entry = root[provider] as? [String: Any],
                  let models = entry["models"] as? [String: Any] else { continue }
            for (model, value) in models {
                try Task.checkCancellation()
                guard !model.isEmpty, model.utf8.count <= 256, !model.contains("/"),
                      let object = value as? [String: Any],
                      let cost = object["cost"] as? [String: Any],
                      let input = AICostReferenceNumber.nonnegative(cost["input"]),
                      let output = AICostReferenceNumber.nonnegative(cost["output"]) else { continue }
                // 非法可选价格作为缺失处理，只有实际使用该类别时才无法估算。
                prices[model] = AIModelPrice(input: input, output: output,
                    cacheRead: AICostReferenceNumber.nonnegative(cost["cache_read"]),
                    cacheWrite: AICostReferenceNumber.nonnegative(cost["cache_write"]))
            }
        }
        guard !prices.isEmpty else { throw AICostReferenceError.invalidResponse }
        return Self(prices: prices, fetchedAt: fetchedAt)
    }
}

public struct AIExchangeRate: Codable, Equatable, Sendable {
    public let cnyPerUSD: Double
    public let fetchedAt: Date

    public init(cnyPerUSD: Double, fetchedAt: Date) {
        self.cnyPerUSD = cnyPerUSD; self.fetchedAt = fetchedAt
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> Self {
        guard data.count <= AICostReferenceStore.exchangeLimit,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["result"] as? String == "success", root["base_code"] as? String == "USD",
              let rates = root["rates"] as? [String: Any],
              let rate = AICostReferenceNumber.nonnegative(rates["CNY"]), rate > 0 else {
            throw AICostReferenceError.invalidResponse
        }
        return Self(cnyPerUSD: rate, fetchedAt: fetchedAt)
    }
}

public struct AICostReferenceSnapshot: Equatable, Sendable {
    public let catalog: AIPriceCatalog?
    public let exchangeRate: AIExchangeRate?

    public init(catalog: AIPriceCatalog?, exchangeRate: AIExchangeRate?) {
        self.catalog = catalog; self.exchangeRate = exchangeRate
    }
}

enum AICostReferenceError: Error, Equatable { case invalidResponse, responseTooLarge }

private enum AICostReferenceNumber {
    static func nonnegative(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
}
