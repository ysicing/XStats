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

  /// 仅保存累计摘要；本机日志与 Magpie 的统计范围不同，不能混称为终身用量。
  public struct TokenUsage: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable {
      case recentYear, all
    }

    public let provider: String
    public let input: Int
    public let output: Int
    public let scope: Scope
    public let isStale: Bool

    public init(provider: String, input: Int, output: Int, scope: Scope, isStale: Bool = false) {
      self.provider = provider
      self.input = max(0, input)
      self.output = max(0, output)
      self.scope = scope
      self.isStale = isStale
    }

    public var total: Int { Self.sum([input, output]) }

    /// 摘要可能已在来源端封顶，跨来源合计仍须防止溢出。
    public static func sum(_ counts: [Int]) -> Int {
      counts.reduce(0) {
        let (sum, overflow) = $0.addingReportingOverflow(max(0, $1))
        return overflow ? Int.max : sum
      }
    }
  }

  public struct CalendarSummary: Codable, Equatable, Sendable {
    public enum Schedule: String, Codable, Sendable {
      case work, weekend, holiday, makeupWork, makeupDayOff, unknown
      /// 有放假数据但未细分法定假日与调休的年份。
      case dayOff
      /// 用户未启用中国大陆节假日；与数据未覆盖的 unknown 分开提示。
      case holidaysDisabled

      /// 数据未覆盖的年份不能按普通工作日推断，避免给出错误的二元答案。
      public var needsWork: Bool? {
        switch self {
        case .work, .makeupWork: true
        case .weekend, .holiday, .makeupDayOff, .dayOff: false
        case .unknown, .holidaysDisabled: nil
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

    public init(
      dateKey: String, festivals: [String], solarTerm: String?,
      schedule: Schedule, holidayName: String?, twelveStar: String?, isEcliptic: Bool,
      recommends: [String], avoids: [String], seasonalDescriptions: [String]? = nil
    ) {
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

    public init(
      dateKey: String, number: Int, subtitle: String, holidayName: String?,
      isWork: Bool?, isWeekend: Bool
    ) {
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

    public init(
      provider: String, kind: String, remainingPercent: Double, resetsAt: Date?,
      fetchedAt: Date, isStale: Bool
    ) {
      self.provider = provider
      self.kind = kind
      self.remainingPercent = remainingPercent
      self.resetsAt = resetsAt
      self.fetchedAt = fetchedAt
      self.isStale = isStale
    }

    /// 只有明确的周窗口才可按七天计算；未知周期不能伪装成周重置。
    public func weeklyResetFraction(at date: Date) -> Double? {
      guard kind == "7 days" || kind == "7d" || kind == "weekly" || kind.hasSuffix("Weekly"),
        let resetsAt
      else { return nil }
      let remaining = resetsAt.timeIntervalSince(date)
      guard remaining.isFinite else { return nil }
      return min(1, max(0, remaining / (7 * 24 * 3600)))
    }
  }

  /// 按 Magpie 返回顺序保存账号摘要；每个服务首项为默认账号，不以最近请求标记替代。
  public struct QuotaAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: String
    public let name: String
    public let quota: Quota?

    public init(id: String, provider: String, name: String, quota: Quota?) {
      self.id = id
      self.provider = provider
      self.name = name
      self.quota = quota
    }
  }

  public struct QuotaSlot: Equatable, Sendable, Identifiable {
    public let provider: String
    public let quota: Quota?
    public var id: String { provider }
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

    public init(
      family: String, ip: String, countryCode: String?, city: String?,
      organization: String?, purityScore: Int?, purityGrade: String?,
      region: String? = nil, cityEnglish: String? = nil, regionEnglish: String? = nil,
      asn: String? = nil, isNative: Bool? = nil, ipType: String? = nil,
      riskFlags: [String]? = nil
    ) {
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
  /// 可选以兼容旧缓存；缺失表示尚无累计摘要，不能用今日用量冒充。
  public var cumulativeTokens: [TokenUsage]?
  /// 保留无有效额度的服务身份，过期或暂时失败不能让后面的圆环前移。
  public var quotaProviders: [String]?
  /// 只保存账号身份、显示名与额度，不包含凭据；nil 兼容旧版摘要。
  public var quotaAccounts: [QuotaAccount]?
  public var preferredQuotaAccounts: [String: String]?
  public var quotaShowsResetRing: Bool?
  /// 可选以兼容旧版摘要；缺失时沿用 AI 总开关的旧行为。
  public var localUsageEnabled: Bool?
  /// 可选显示偏好；旧摘要沿用剩余额度和按语言缩写。
  public var quotaShowsRemaining: Bool?
  public var westernUnits: Bool?
  public var publicIPEnabled: Bool
  public var addresses: [Address]
  public var language: String
  public var calendarFirstWeekday: Int
  public var showsLunar: Bool
  /// 可选以兼容旧版摘要；单日日历仅在用户开启时显示具体时令天数。
  public var showsSeasonal: Bool?
  /// 保留旧字段以识别黄历曾关闭的缓存；主应用固定写入 true，并重算旧的 nil / false 摘要。
  public var showsAlmanac: Bool?
  /// 可选以兼容旧版主应用写入的 App Group 摘要。
  public var calendarDays: [CalendarSummary]?
  /// 当前与下个月的六周网格；旧版缓存缺失时 Widget 仍显示公历日期。
  public var monthSummaries: [MonthSummary]?
  /// 写入日历摘要的主应用构建号；新版可能内置新的放假数据，构建号不同时不复用缓存。
  public var calendarDataVersion: String?
  public init(
    aiEnabled: Bool = false, quotas: [Quota] = [], dailyTokens: [DailyTokenUsage]? = nil,
    cumulativeTokens: [TokenUsage]? = nil, quotaProviders: [String]? = nil,
    quotaAccounts: [QuotaAccount]? = nil,
    preferredQuotaAccounts: [String: String]? = nil, quotaShowsResetRing: Bool? = nil,
    localUsageEnabled: Bool? = nil, quotaShowsRemaining: Bool? = nil, westernUnits: Bool? = nil,
    publicIPEnabled: Bool = false,
    addresses: [Address] = [], language: String = "system",
    calendarFirstWeekday: Int = Calendar.current.firstWeekday,
    showsLunar: Bool = Locale.current.region?.identifier == "CN",
    calendarDays: [CalendarSummary]? = nil, monthSummaries: [MonthSummary]? = nil,
    showsSeasonal: Bool? = nil, calendarDataVersion: String? = nil, showsAlmanac: Bool? = nil
  ) {
    self.aiEnabled = aiEnabled
    self.quotas = quotas
    self.dailyTokens = dailyTokens
    self.cumulativeTokens = cumulativeTokens
    self.quotaProviders = quotaProviders
    self.quotaAccounts = quotaAccounts
    self.preferredQuotaAccounts = preferredQuotaAccounts
    self.quotaShowsResetRing = quotaShowsResetRing
    self.localUsageEnabled = localUsageEnabled
    self.quotaShowsRemaining = quotaShowsRemaining
    self.westernUnits = westernUnits
    self.publicIPEnabled = publicIPEnabled
    self.addresses = addresses
    self.language = language
    self.calendarFirstWeekday = calendarFirstWeekday
    self.showsLunar = showsLunar
    self.showsSeasonal = showsSeasonal
    self.showsAlmanac = showsAlmanac
    self.calendarDays = calendarDays
    self.monthSummaries = monthSummaries
    self.calendarDataVersion = calendarDataVersion
  }

  public var showsLocalUsage: Bool { aiEnabled && localUsageEnabled != false }

  public var visibleCumulativeTokens: [TokenUsage] {
    showsLocalUsage ? (cumulativeTokens ?? []) : []
  }

  /// 默认四个品牌保留位置；其他服务仅占用未使用的位置，额度失效不影响排序。
  public func quotaSlots(at date: Date = .now) -> [QuotaSlot] {
    let defaults = ["codex", "claude", "gemini", "grok"]
    let providers =
      quotaProviders
      ?? (defaults.filter { provider in quotas.contains { $0.provider == provider } }
        + Set(quotas.map(\.provider)).subtracting(defaults).sorted())
    var ordered = defaults
    let vacancies = defaults.indices.filter { !providers.contains(defaults[$0]) }
    var filled = 0
    for provider in providers where !ordered.contains(provider) && !provider.isEmpty {
      guard filled < vacancies.count else { break }
      ordered[vacancies[filled]] = provider
      filled += 1
    }
    let current = currentQuotas(at: date).filter { $0.remainingPercent.isFinite }
    return ordered.map { provider in
      let selectedID = preferredQuotaAccounts?[provider]
      if let quotaAccounts {
        let accounts = quotaAccounts.filter { $0.provider == provider }
        // 显式选择缺失或身份有歧义时不能回退到别的账号。
        let account: QuotaAccount?
        if let selectedID {
          let matching = accounts.filter { $0.id == selectedID }
          account = matching.count == 1 ? matching.first : nil
        } else {
          account = accounts.first
        }
        let quota = aiEnabled ? account?.quota : nil
        let valid = quota.flatMap {
          $0.remainingPercent.isFinite && ($0.resetsAt.map { $0 > date } ?? true) ? $0 : nil
        }
        return QuotaSlot(provider: provider, quota: valid)
      }
      guard selectedID == nil else { return QuotaSlot(provider: provider, quota: nil) }
      let windows = current.filter { $0.provider == provider }
      let quota =
        windows.first { $0.kind == "weekly" || $0.kind.hasSuffix("Weekly") }
        ?? windows.first { $0.kind == "session" } ?? windows.first
      return QuotaSlot(provider: provider, quota: quota)
    }
  }

  /// 已过重置时间的缓存不再代表当前额度，Widget 不应继续显示旧百分比。
  public func currentQuotas(at date: Date = .now) -> [Quota] {
    guard aiEnabled else { return [] }
    return quotas.filter { $0.resetsAt.map { $0 > date } ?? true }
  }

  /// 旧日快照保留来源，但数值归零；Widget 不得把昨天的使用量当作今天的结果。
  public func todayTokens(
    for provider: String, at date: Date = .now,
    calendar: Calendar = .autoupdatingCurrent
  ) -> Int? {
    guard showsLocalUsage, let usage = dailyTokens?.first(where: { $0.provider == provider }) else {
      return nil
    }
    return calendar.isDate(usage.day, inSameDayAs: date) ? usage.tokens : 0
  }

  public var visibleAddresses: [Address] { publicIPEnabled ? addresses : [] }

  /// 只比较各 Widget 实际显示的字段。重载会消耗系统分配的刷新预算，
  /// 额度的抓取时间不在 Widget 上显示，仅它变化时不重载。
  public func changedWidgetKinds(from previous: WidgetSnapshot) -> [String] {
    func displayed(_ quotas: [Quota]) -> [Quota] {
      quotas.map {
        Quota(
          provider: $0.provider, kind: $0.kind, remainingPercent: $0.remainingPercent,
          resetsAt: $0.resetsAt, fetchedAt: .distantPast, isStale: $0.isStale)
      }
    }
    func displayedAccounts(_ accounts: [QuotaAccount]?) -> [QuotaAccount]? {
      accounts?.map {
        QuotaAccount(
          id: $0.id, provider: $0.provider, name: $0.name,
          quota: $0.quota.flatMap { displayed([$0]).first })
      }
    }
    let relocalized = language != previous.language
    let quotaChanged =
      relocalized || aiEnabled != previous.aiEnabled
      || (quotaShowsRemaining != false) != (previous.quotaShowsRemaining != false)
    let localUsageChanged =
      relocalized || showsLocalUsage != previous.showsLocalUsage
      || (westernUnits == true) != (previous.westernUnits == true)
    var kinds: [String] = []
    if quotaChanged || quotaProviders != previous.quotaProviders
      || preferredQuotaAccounts != previous.preferredQuotaAccounts
      || (quotaShowsResetRing == true) != (previous.quotaShowsResetRing == true)
      || displayed(quotas) != displayed(previous.quotas)
      || displayedAccounts(quotaAccounts) != displayedAccounts(previous.quotaAccounts)
    {
      kinds.append(WidgetKind.aiQuota)
    }
    if localUsageChanged || dailyTokens != previous.dailyTokens
      || cumulativeTokens != previous.cumulativeTokens
    {
      kinds.append(WidgetKind.todayTokens)
    }
    if relocalized || publicIPEnabled != previous.publicIPEnabled
      || visibleAddresses != previous.visibleAddresses
    {
      kinds += [WidgetKind.ipPurity, WidgetKind.publicIP]
    }
    let calendarChanged =
      relocalized || calendarFirstWeekday != previous.calendarFirstWeekday
      || showsLunar != previous.showsLunar || calendarDays != previous.calendarDays
    if calendarChanged {
      kinds += [WidgetKind.calendar, WidgetKind.tomorrowWork]
    } else if showsSeasonal != previous.showsSeasonal {
      kinds.append(WidgetKind.calendar)
    }
    if relocalized || calendarFirstWeekday != previous.calendarFirstWeekday
      || monthSummaries != previous.monthSummaries
    {
      kinds.append(WidgetKind.calendarMonth)
    }
    if relocalized { kinds.append(WidgetKind.system) }
    return kinds
  }

  public func monthSummary(for date: Date, calendar: Calendar = keyCalendar) -> MonthSummary? {
    let key = Self.monthKey(for: date, calendar: calendar)
    return monthSummaries?.first { $0.monthKey == key }
  }

  public func calendarSummary(for date: Date, calendar: Calendar = keyCalendar) -> CalendarSummary?
  {
    let key = Self.dayKey(for: date, calendar: calendar)
    return calendarDays?.first { $0.dateKey == key }
  }

  /// 主应用与 Widget 共用的日期键固定用公历；系统日历为佛历、和历时年份才不会错位。
  public static var keyCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    return calendar
  }

  public static func dayKey(year: Int, month: Int, day: Int) -> String {
    String(format: "%04d-%02d-%02d", year, month, day)
  }

  public static func monthKey(year: Int, month: Int) -> String {
    String(format: "%04d-%02d", year, month)
  }

  public static func dayKey(for date: Date, calendar: Calendar = keyCalendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return dayKey(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
  }

  public static func monthKey(for date: Date, calendar: Calendar = keyCalendar) -> String {
    let parts = calendar.dateComponents([.year, .month], from: date)
    return monthKey(year: parts.year ?? 0, month: parts.month ?? 0)
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
    loadIfAvailable() ?? WidgetSnapshot()
  }

  /// 缺失、无权读取或损坏的摘要不能代表用户关闭了功能；展示端须保留这个区别。
  public func loadIfAvailable() -> WidgetSnapshot? {
    guard let data = defaults?.data(forKey: Self.key),
      let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    else { return nil }
    return snapshot
  }

  @discardableResult
  public func save(_ snapshot: WidgetSnapshot) -> Bool {
    guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return false }
    defaults.set(data, forKey: Self.key)
    return true
  }
}
