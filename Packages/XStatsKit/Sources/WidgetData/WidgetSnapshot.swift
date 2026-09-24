// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 跨进程共享的展示摘要，不包含账号凭据、请求内容或本机 Token 日志。
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Quota: Codable, Equatable, Sendable {
        public let provider: String
        public let kind: String
        public let remainingPercent: Double
        public let resetsAt: Date?
        public let fetchedAt: Date
        public let isStale: Bool

        public init(provider: String, kind: String, remainingPercent: Double, resetsAt: Date?,
                    fetchedAt: Date, isStale: Bool) {
            self.provider = provider
            self.kind = kind
            self.remainingPercent = remainingPercent
            self.resetsAt = resetsAt
            self.fetchedAt = fetchedAt
            self.isStale = isStale
        }
    }

    public struct Address: Codable, Equatable, Sendable {
        public let family: String
        public let ip: String
        public let countryCode: String?
        public let city: String?
        public let organization: String?
        public let purityScore: Int?
        public let purityGrade: String?

        public init(family: String, ip: String, countryCode: String?, city: String?,
                    organization: String?, purityScore: Int?, purityGrade: String?) {
            self.family = family
            self.ip = ip
            self.countryCode = countryCode
            self.city = city
            self.organization = organization
            self.purityScore = purityScore
            self.purityGrade = purityGrade
        }
    }

    public var aiEnabled: Bool
    public var quotas: [Quota]
    public var publicIPEnabled: Bool
    public var addresses: [Address]
    public var language: String
    public var calendarFirstWeekday: Int
    public var showsLunar: Bool

    public init(aiEnabled: Bool = false, quotas: [Quota] = [], publicIPEnabled: Bool = false,
                addresses: [Address] = [], language: String = "system",
                calendarFirstWeekday: Int = 2, showsLunar: Bool = true) {
        self.aiEnabled = aiEnabled
        self.quotas = quotas
        self.publicIPEnabled = publicIPEnabled
        self.addresses = addresses
        self.language = language
        self.calendarFirstWeekday = calendarFirstWeekday
        self.showsLunar = showsLunar
    }

    /// 已过重置时间的缓存不再代表当前额度，Widget 不应继续显示旧百分比。
    public func currentQuotas(at date: Date = .now) -> [Quota] {
        guard aiEnabled else { return [] }
        return quotas.filter { $0.resetsAt.map { $0 > date } ?? true }
    }

    public var visibleAddresses: [Address] { publicIPEnabled ? addresses : [] }
}

public struct WidgetSnapshotStore {
    public static let appGroup = "group.work.12306.xstats"
    private static let key = "widgetSnapshotV1"
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        self.defaults = defaults
    }

    public func load() -> WidgetSnapshot {
        guard let data = defaults?.data(forKey: Self.key),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return snapshot
    }

    @discardableResult
    public func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}
