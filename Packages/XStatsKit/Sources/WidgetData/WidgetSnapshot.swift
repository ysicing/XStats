// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 跨进程共享的展示摘要，不包含账号凭据、请求内容或本机 Token 日志。
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct CalendarSummary: Codable, Equatable, Sendable {
        public enum Schedule: String, Codable, Sendable {
            case work, dayOff, makeupWork, unknown

            /// 数据未覆盖的年份不能按普通工作日推断，避免给出错误的二元答案。
            public var needsWork: Bool? {
                switch self {
                case .work, .makeupWork: true
                case .dayOff: false
                case .unknown: nil
                }
            }
        }

        public let dateKey: String
        public let festivals: [String]
        public let solarTerm: String?
        public let schedule: Schedule
        public let holidayName: String?
        public let twelveStar: String?
        public let isEcliptic: Bool
        public let recommends: [String]
        public let avoids: [String]

        public init(dateKey: String, festivals: [String], solarTerm: String?,
                    schedule: Schedule, holidayName: String?, twelveStar: String?, isEcliptic: Bool,
                    recommends: [String], avoids: [String]) {
            self.dateKey = dateKey
            self.festivals = festivals
            self.solarTerm = solarTerm
            self.schedule = schedule
            self.holidayName = holidayName
            self.twelveStar = twelveStar
            self.isEcliptic = isEcliptic
            self.recommends = recommends
            self.avoids = avoids
        }
    }

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
    /// 可选以兼容旧版主应用写入的 App Group 摘要。
    public var calendarDays: [CalendarSummary]?

    public init(aiEnabled: Bool = false, quotas: [Quota] = [], publicIPEnabled: Bool = false,
                addresses: [Address] = [], language: String = "system",
                calendarFirstWeekday: Int = 2, showsLunar: Bool = true,
                calendarDays: [CalendarSummary]? = nil) {
        self.aiEnabled = aiEnabled
        self.quotas = quotas
        self.publicIPEnabled = publicIPEnabled
        self.addresses = addresses
        self.language = language
        self.calendarFirstWeekday = calendarFirstWeekday
        self.showsLunar = showsLunar
        self.calendarDays = calendarDays
    }

    /// 已过重置时间的缓存不再代表当前额度，Widget 不应继续显示旧百分比。
    public func currentQuotas(at date: Date = .now) -> [Quota] {
        guard aiEnabled else { return [] }
        return quotas.filter { $0.resetsAt.map { $0 > date } ?? true }
    }

    public var visibleAddresses: [Address] { publicIPEnabled ? addresses : [] }

    public func calendarSummary(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> CalendarSummary? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        return calendarDays?.first { $0.dateKey == key }
    }
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
