// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreFoundation
import Foundation

/// 套餐与重置券的只读摘要；不保存账号、令牌、券 ID 或可执行的重置操作。
public struct AIQuotaDetails: Codable, Equatable, Sendable {
    public var plan: String?
    public var subscriptionValidFrom: Date?
    public var subscriptionValidUntil: Date?
    public var resetCredits: Int?
    public var resetCreditsExpireAt: Date?

    public init(plan: String? = nil, subscriptionValidUntil: Date? = nil,
                resetCredits: Int? = nil, resetCreditsExpireAt: Date? = nil, subscriptionValidFrom: Date? = nil) {
        self.plan = plan
        self.subscriptionValidFrom = subscriptionValidFrom
        self.subscriptionValidUntil = subscriptionValidUntil
        self.resetCredits = resetCredits
        self.resetCreditsExpireAt = resetCreditsExpireAt
    }

    /// 使用真实起止时间计算剩余有效期；缺少起点时不假定月付或 30 天周期。
    public func subscriptionRemainingFraction(at now: Date) -> Double? {
        guard let start = subscriptionValidFrom, let end = subscriptionValidUntil,
              start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite, end > start else { return nil }
        let duration = end.timeIntervalSince(start)
        let remaining = end.timeIntervalSince(now)
        guard duration.isFinite, remaining.isFinite else { return nil }
        return min(1, max(0, remaining / duration))
    }

    static func parse(plan: Any?, resets: [String: Any]?, appServer: Bool, now: Date) -> Self {
        let plan = (plan as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = Self(plan: plan.flatMap { !$0.isEmpty && $0.count <= 64 && $0 != "unknown" ? $0 : nil })
        value.resetCredits = count(resets?[appServer ? "availableCount" : "available_count"])
        guard let count = value.resetCredits, count > 0,
              let credits = resets?["credits"] as? [[String: Any]] else { return value }
        let iso = ISO8601Parser()
        value.resetCreditsExpireAt = credits.lazy.filter { $0["status"] as? String == "available" }.compactMap { credit in
            let date: Date?
            if appServer, let number = credit["expiresAt"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
               number.doubleValue > 0, number.doubleValue < 253_402_300_800 {
                date = Date(timeIntervalSince1970: number.doubleValue)
            } else {
                date = iso.date(credit["expires_at"])
            }
            return date.flatMap { $0 > now ? $0 : nil }
        }.min()
        return value
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1_000_000,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
}
