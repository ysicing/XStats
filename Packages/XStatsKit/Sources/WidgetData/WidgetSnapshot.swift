// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 跨进程共享的展示摘要，不包含账号凭据、请求内容或本机会话日志。
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct DailyTokenUsage: Codable, Equatable, Sendable {
        public let provider: String
        public let day: Date
        public let tokens: Int

        public init(provider: String, day: Date, tokens: Int) {
            self.provider = provider
            self.day = day
            self.tokens = tokens
        }
    }

    public struct CalendarSummary: Codable, Equatable, Sendable {
        public enum Schedule: String, Codable, Sendable {
            case work, weekend, holiday, makeupWork, makeupDayOff, unknown
            case dayOff // 兼容旧版 App Group 摘要；新版会在下次同步时重算。

            /// 数据未覆盖的年份不能按普通工作日推断，避免给出错误的二元答案。
            public var needsWork: Bool? {
                switch self {
                case .work, .makeupWork: true
                case .weekend, .holiday, .makeupDayOff, .dayOff: false
                case .unknown: nil
                }
            }
        }

        public let dateKey: String
        public let festivals: [String]
        public let solarTerm: String?
        public let schedule: Schedule
        public let holidayName: String?
        public let seasonalDescriptions: [String]?
        public let twelveStar: String?
        public let isEcliptic: Bool
        public let recommends: [String]
        public let avoids: [String]

        public init(dateKey: String, festivals: [String], solarTerm: String?,
                    schedule: Schedule, holidayName: String?, twelveStar: String?, isEcliptic: Bool,
                    recommends: [String], avoids: [String], seasonalDescriptions: [String]? = nil) {
            self.dateKey = dateKey
            self.festivals = festivals
            self.solarTerm = solarTerm
            self.schedule = schedule
            self.holidayName = holidayName
            self.seasonalDescriptions = seasonalDescriptions
            self.twelveStar = twelveStar
            self.isEcliptic = isEcliptic
            self.recommends = recommends
            self.avoids = avoids
        }
    }

    /// 月历只保存格子需要的文字与休班标记，不复制每日黄历详情。
    public struct MonthDay: Codable, Equatable, Sendable {
        public let dateKey: String
        public let number: Int
        public let subtitle: String
        public let holidayName: String?
        public let isWork: Bool?
        public let isWeekend: Bool

        public init(dateKey: String, number: Int, subtitle: String, holidayName: String?,
                    isWork: Bool?, isWeekend: Bool) {
            self.dateKey = dateKey
            self.number = number
            self.subtitle = subtitle
            self.holidayName = holidayName
            self.isWork = isWork
            self.isWeekend = isWeekend
        }
    }

    public struct MonthSummary: Codable, Equatable, Sendable {
        public let monthKey: String
        public let firstWeekday: Int
        /// 主应用用它判断设置变化后是否需要重算缓存。
        public let featureKeys: [String]
        public let days: [MonthDay]

        public init(monthKey: String, firstWeekday: Int, featureKeys: [String], days: [MonthDay]) {
            self.monthKey = monthKey
            self.firstWeekday = firstWeekday
            self.featureKeys = featureKeys
            self.days = days
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
        public let region: String?
        public let cityEnglish: String?
        public let regionEnglish: String?
        public let asn: String?
        public let organization: String?
        public let isNative: Bool?
        public let ipType: String?
        /// nil 表示尚无风险查询结果；空数组表示已查询且未检出标记。
        public let riskFlags: [String]?
        public let purityScore: Int?
        public let purityGrade: String?

        public init(family: String, ip: String, countryCode: String?, city: String?,
                    organization: String?, purityScore: Int?, purityGrade: String?,
                    region: String? = nil, cityEnglish: String? = nil, regionEnglish: String? = nil,
                    asn: String? = nil, isNative: Bool? = nil, ipType: String? = nil,
                    riskFlags: [String]? = nil) {
            self.family = family
            self.ip = ip
            self.countryCode = countryCode
            self.city = city
            self.region = region
            self.cityEnglish = cityEnglish
            self.regionEnglish = regionEnglish
            self.asn = asn
            self.organization = organization
            self.isNative = isNative
            self.ipType = ipType
            self.riskFlags = riskFlags
            self.purityScore = purityScore
            self.purityGrade = purityGrade
        }
    }

    public var aiEnabled: Bool
    public var quotas: [Quota]
    /// 仅共享每个来源的当日合计；可选以兼容旧版 App Group 摘要。
    public var dailyTokens: [DailyTokenUsage]?
    /// 可选以兼容旧版摘要；缺失时沿用 AI 总开关的旧行为。
    public var localUsageEnabled: Bool?
    public var publicIPEnabled: Bool
    public var addresses: [Address]
    public var language: String
    public var calendarFirstWeekday: Int
    public var showsLunar: Bool
    /// 可选以兼容旧版摘要；单日日历仅在用户开启时显示具体时令天数。
    public var showsSeasonal: Bool?
    /// 可选以兼容旧版主应用写入的 App Group 摘要。
    public var calendarDays: [CalendarSummary]?
    /// 当前与下个月的六周网格；旧版缓存缺失时 Widget 仍显示公历日期。
    public var monthSummaries: [MonthSummary]?

    public init(aiEnabled: Bool = false, quotas: [Quota] = [], dailyTokens: [DailyTokenUsage]? = nil,
                localUsageEnabled: Bool? = nil,
                publicIPEnabled: Bool = false,
                addresses: [Address] = [], language: String = "system",
                calendarFirstWeekday: Int = 2, showsLunar: Bool = true,
                calendarDays: [CalendarSummary]? = nil, monthSummaries: [MonthSummary]? = nil,
                showsSeasonal: Bool? = nil) {
        self.aiEnabled = aiEnabled
        self.quotas = quotas
        self.dailyTokens = dailyTokens
        self.localUsageEnabled = localUsageEnabled
        self.publicIPEnabled = publicIPEnabled
        self.addresses = addresses
        self.language = language
        self.calendarFirstWeekday = calendarFirstWeekday
        self.showsLunar = showsLunar
        self.showsSeasonal = showsSeasonal
        self.calendarDays = calendarDays
        self.monthSummaries = monthSummaries
    }

    public var showsLocalUsage: Bool { aiEnabled && localUsageEnabled != false }

    /// 已过重置时间的缓存不再代表当前额度，Widget 不应继续显示旧百分比。
    public func currentQuotas(at date: Date = .now) -> [Quota] {
        guard aiEnabled else { return [] }
        return quotas.filter { $0.resetsAt.map { $0 > date } ?? true }
    }

    /// 旧日快照保留来源，但数值归零；Widget 不得把昨天的使用量当作今天的结果。
    public func todayTokens(for provider: String, at date: Date = .now,
                            calendar: Calendar = .autoupdatingCurrent) -> Int? {
        guard showsLocalUsage, let usage = dailyTokens?.first(where: { $0.provider == provider }) else { return nil }
        return calendar.isDate(usage.day, inSameDayAs: date) ? usage.tokens : 0
    }

    public var visibleAddresses: [Address] { publicIPEnabled ? addresses : [] }

    /// 只比较各 Widget 实际显示的字段。重载会消耗系统分配的刷新预算，
    /// 额度的抓取时间不在 Widget 上显示，仅它变化时不重载。
    public func changedWidgetKinds(from previous: WidgetSnapshot) -> [String] {
        func displayed(_ quotas: [Quota]) -> [Quota] {
            quotas.map { Quota(provider: $0.provider, kind: $0.kind, remainingPercent: $0.remainingPercent,
                               resetsAt: $0.resetsAt, fetchedAt: .distantPast, isStale: $0.isStale) }
        }
        let relocalized = language != previous.language
        let quotaChanged = relocalized || aiEnabled != previous.aiEnabled
        let localUsageChanged = relocalized || showsLocalUsage != previous.showsLocalUsage
        var kinds: [String] = []
        if quotaChanged || displayed(quotas) != displayed(previous.quotas) { kinds.append(WidgetKind.aiQuota) }
        if localUsageChanged || dailyTokens != previous.dailyTokens { kinds.append(WidgetKind.todayTokens) }
        if relocalized || publicIPEnabled != previous.publicIPEnabled
            || visibleAddresses != previous.visibleAddresses {
            kinds += [WidgetKind.ipPurity, WidgetKind.publicIP]
        }
        let calendarChanged = relocalized || calendarFirstWeekday != previous.calendarFirstWeekday
            || showsLunar != previous.showsLunar || calendarDays != previous.calendarDays
        if calendarChanged {
            kinds += [WidgetKind.calendar, WidgetKind.tomorrowWork]
        } else if showsSeasonal != previous.showsSeasonal {
            kinds.append(WidgetKind.calendar)
        }
        if relocalized || calendarFirstWeekday != previous.calendarFirstWeekday || monthSummaries != previous.monthSummaries {
            kinds.append(WidgetKind.calendarMonth)
        }
        return kinds
    }

    public func monthSummary(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> MonthSummary? {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        let key = String(format: "%04d-%02d", year, month)
        return monthSummaries?.first { $0.monthKey == key }
    }

    public func calendarSummary(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> CalendarSummary? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        return calendarDays?.first { $0.dateKey == key }
    }
}

/// 各 Widget 的 kind，主应用据此按需重载
public enum WidgetKind {
    public static let system = "work.12306.xstats.widget.system"
    public static let aiQuota = "work.12306.xstats.widget.aiQuota"
    public static let todayTokens = "work.12306.xstats.widget.todayTokens"
    public static let ipPurity = "work.12306.xstats.widget.ipPurity"
    public static let publicIP = "work.12306.xstats.widget.publicIP"
    public static let calendar = "work.12306.xstats.widget.calendar"
    public static let calendarMonth = "work.12306.xstats.widget.calendarMonth"
    public static let tomorrowWork = "work.12306.xstats.widget.tomorrowWork"
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
