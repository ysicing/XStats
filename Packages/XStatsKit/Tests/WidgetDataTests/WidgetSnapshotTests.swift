// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
import WidgetData

@Test func widgetAccountSelectionFollowsDefaultAndPreservesExplicitIdentity() throws {
  let now = Date()
  func slots(_ snapshot: WidgetSnapshot, id: String, at date: Date) -> [WidgetSnapshot.QuotaSlot] {
    var configured = snapshot
    configured.preferredQuotaAccounts = ["codex": id]
    return configured.quotaSlots(at: date)
  }
  let first = WidgetSnapshot.Quota(
    provider: "codex", kind: "7 days", remainingPercent: 30,
    resetsAt: now.addingTimeInterval(100), fetchedAt: now, isStale: false)
  let other = WidgetSnapshot.Quota(
    provider: "codex", kind: "7 days", remainingPercent: 80,
    resetsAt: now.addingTimeInterval(200), fetchedAt: now, isStale: false)
  let a = WidgetSnapshot.QuotaAccount(id: "a", provider: "codex", name: "A", quota: first)
  let b = WidgetSnapshot.QuotaAccount(id: "b", provider: "codex", name: "B", quota: other)
  var snapshot = WidgetSnapshot(
    aiEnabled: true, quotas: [first], quotaProviders: ["codex"], quotaAccounts: [a, b])
  #expect(snapshot.quotaSlots(at: now).first?.quota == first)
  #expect(slots(snapshot, id: "b", at: now).first?.quota == other)
  let restored = try JSONDecoder().decode(
    WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
  #expect(restored == snapshot)
  snapshot.quotaAccounts = [b, a]
  #expect(snapshot.quotaSlots(at: now).first?.quota == other)
  #expect(slots(snapshot, id: "a", at: now).first?.quota == first)
  #expect(
    slots(snapshot, id: "b", at: now.addingTimeInterval(201)).first?.quota == nil)
  snapshot.quotaAccounts = [a]
  #expect(slots(snapshot, id: "b", at: now).first?.quota == nil)
  snapshot.quotaAccounts = [a, a]
  #expect(slots(snapshot, id: "a", at: now).first?.quota == nil)
  snapshot.quotaAccounts = [.init(id: "a", provider: "codex", name: "A", quota: nil), b]
  #expect(snapshot.quotaSlots(at: now).first?.quota == nil)
  snapshot.aiEnabled = false
  #expect(slots(snapshot, id: "b", at: now).allSatisfy { $0.quota == nil })
  snapshot.aiEnabled = true
  snapshot.quotaAccounts = nil
  #expect(snapshot.quotaSlots(at: now).first?.quota == first)
  #expect(slots(snapshot, id: "b", at: now).first?.quota == nil)
}

@Test func preferredAccountSurvivesProviderReordering() {
  let now = Date()
  let first = WidgetSnapshot.Quota(
    provider: "workbuddy", kind: "7 days", remainingPercent: 10,
    resetsAt: nil, fetchedAt: now, isStale: false)
  let second = WidgetSnapshot.Quota(
    provider: "workbuddy", kind: "7 days", remainingPercent: 90,
    resetsAt: nil, fetchedAt: now, isStale: false)
  var snapshot = WidgetSnapshot(
    aiEnabled: true, quotaProviders: ["workbuddy"],
    quotaAccounts: [
      .init(id: "a", provider: "workbuddy", name: "A", quota: first),
      .init(id: "b", provider: "workbuddy", name: "B", quota: second),
    ], preferredQuotaAccounts: ["workbuddy": "b"])
  #expect(snapshot.quotaSlots(at: now).first?.quota == second)
  snapshot.quotaProviders = ["codex", "workbuddy"]
  #expect(snapshot.quotaSlots(at: now)[1].provider == "workbuddy")
  #expect(snapshot.quotaSlots(at: now)[1].quota == second)
  snapshot.preferredQuotaAccounts = [:]
  #expect(snapshot.quotaSlots(at: now)[1].quota == first)
}

@Test func widgetAccountChangesReloadWithoutReloadingForReadTimeOnly() {
  let now = Date()
  func snapshot(name: String = "A", fetchedAt: Date, remaining: Double = 50) -> WidgetSnapshot {
    WidgetSnapshot(
      aiEnabled: true, quotaProviders: ["workbuddy"],
      quotaAccounts: [
        .init(
          id: "account", provider: "workbuddy", name: name,
          quota: .init(
            provider: "workbuddy", kind: "7 days", remainingPercent: remaining,
            resetsAt: nil, fetchedAt: fetchedAt, isStale: false))
      ])
  }
  let previous = snapshot(fetchedAt: now)
  #expect(
    snapshot(fetchedAt: now.addingTimeInterval(10)).changedWidgetKinds(from: previous).isEmpty)
  // 名称不在小组件上绘制，改别名不需要重载。
  #expect(snapshot(name: "Renamed", fetchedAt: now).changedWidgetKinds(from: previous).isEmpty)
  #expect(
    snapshot(fetchedAt: now, remaining: 20).changedWidgetKinds(from: previous) == [
      WidgetKind.aiQuota
    ])
  var removed = previous
  removed.quotaAccounts = []
  #expect(removed.changedWidgetKinds(from: previous) == [WidgetKind.aiQuota])
  var configured = previous
  configured.preferredQuotaAccounts = ["workbuddy": "account"]
  #expect(configured.changedWidgetKinds(from: previous) == [WidgetKind.aiQuota])
  configured.quotaProviders = ["codex", "workbuddy"]
  #expect(configured.quotaSlots(at: now).first { $0.provider == "workbuddy" }?.quota != nil)
  configured.quotaShowsResetRing = true
  #expect(configured.changedWidgetKinds(from: previous) == [WidgetKind.aiQuota])
}

@Test func widgetIgnoresQuotaChangesOfAccountsItDoesNotDraw() {
  let now = Date()
  func snapshot(preferredRemaining: Double, otherRemaining: Double) -> WidgetSnapshot {
    func account(_ id: String, remaining: Double) -> WidgetSnapshot.QuotaAccount {
      .init(
        id: id, provider: "codex", name: id,
        quota: .init(
          provider: "codex", kind: "7 days", remainingPercent: remaining,
          resetsAt: nil, fetchedAt: now, isStale: false))
    }
    return WidgetSnapshot(
      aiEnabled: true, quotaProviders: ["codex"],
      quotaAccounts: [
        account("preferred", remaining: preferredRemaining),
        account("other", remaining: otherRemaining),
      ], preferredQuotaAccounts: ["codex": "preferred"])
  }
  let previous = snapshot(preferredRemaining: 80, otherRemaining: 40)
  // 未绘制的备用账号每次刷新都会变化，不应消耗小组件重载预算。
  #expect(
    snapshot(preferredRemaining: 80, otherRemaining: 39).changedWidgetKinds(from: previous)
      .isEmpty)
  #expect(
    snapshot(preferredRemaining: 79, otherRemaining: 40).changedWidgetKinds(from: previous)
      == [WidgetKind.aiQuota])
}

@Test func missingAndCorruptSnapshotsDoNotMeanDisabledModules() throws {
  let suite = "WidgetSnapshotAvailability.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let store = WidgetSnapshotStore(defaults: defaults)
  #expect(store.loadIfAvailable() == nil)
  #expect(WidgetSnapshotStore(defaults: nil).loadIfAvailable() == nil)

  // 有效的全关闭摘要与没有摘要必须区分，旧格式仍按原协议解码。
  let disabled = WidgetSnapshot()
  #expect(store.save(disabled))
  #expect(store.loadIfAvailable() == disabled)
  let key = try #require(
    defaults.persistentDomain(forName: suite)?.first { $0.value is Data }?.key)
  defaults.set(Data("invalid JSON".utf8), forKey: key)
  #expect(store.loadIfAvailable() == nil)
  defaults.set(
    Data(
      #"{"aiEnabled":false,"quotas":[],"publicIPEnabled":false,"addresses":[],"language":"system","calendarFirstWeekday":2,"showsLunar":true}"#
        .utf8), forKey: key)
  #expect(store.loadIfAvailable()?.aiEnabled == false)
}

@Test func snapshotRoundTripAndDisabledModules() throws {
  let suite = "WidgetSnapshotTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let store = WidgetSnapshotStore(defaults: defaults)
  let now = Date()
  let snapshot = WidgetSnapshot(
    aiEnabled: true,
    quotas: [
      .init(
        provider: "codex", kind: "weekly", remainingPercent: 37,
        resetsAt: now.addingTimeInterval(60),
        fetchedAt: now, isStale: false)
    ],
    publicIPEnabled: true,
    addresses: [
      .init(
        family: "v4", ip: "203.0.113.1", countryCode: "CN", city: nil,
        organization: nil, purityScore: 82, purityGrade: "A")
    ],
    language: "japanese", calendarFirstWeekday: 1, showsLunar: false, showsAlmanac: false)
  #expect(store.save(snapshot))
  #expect(store.load() == snapshot)
  #expect(snapshot.currentQuotas(at: now).count == 1)
  #expect(snapshot.currentQuotas(at: now.addingTimeInterval(61)).isEmpty)

  var disabled = snapshot
  disabled.aiEnabled = false
  disabled.publicIPEnabled = false
  #expect(disabled.currentQuotas(at: now).isEmpty)
  #expect(disabled.visibleAddresses.isEmpty)
}

@Test(arguments: Array(1...7))
func snapshotPreservesEveryWeekStartAndReloadsCalendars(firstWeekday: Int) throws {
  let previous = WidgetSnapshot(calendarFirstWeekday: firstWeekday % 7 + 1)
  let snapshot = WidgetSnapshot(calendarFirstWeekday: firstWeekday)
  let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
  #expect(restored.calendarFirstWeekday == firstWeekday)
  #expect(
    restored.changedWidgetKinds(from: previous) == [
      WidgetKind.calendar, WidgetKind.tomorrowWork, WidgetKind.calendarMonth,
    ])
}

@Test func calendarSummaryUsesLocalCivilDayAndOldCacheStillDecodes() throws {
  let legacy = Data(
    #"{"aiEnabled":false,"quotas":[],"publicIPEnabled":false,"addresses":[],"language":"system","calendarFirstWeekday":2,"showsLunar":true}"#
      .utf8)
  let oldSnapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: legacy)
  #expect(oldSnapshot.calendarDays == nil)
  #expect(oldSnapshot.showsSeasonal == nil)

  let day = WidgetSnapshot.CalendarSummary(
    dateKey: "2026-09-25", festivals: ["中秋节"],
    solarTerm: nil, schedule: .dayOff, holidayName: "中秋节",
    twelveStar: "除", isEcliptic: true,
    recommends: ["祭祀"], avoids: ["动土"])
  var snapshot = oldSnapshot
  snapshot.calendarDays = [day]
  let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-24T16:00:00Z"))
  var shanghai = Calendar(identifier: .gregorian)
  shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  #expect(snapshot.calendarSummary(for: instant, calendar: shanghai) == day)
  #expect(snapshot.calendarSummary(for: instant, calendar: utc) == nil)
  #expect(
    try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
}

@Test func dateKeysStayGregorianWhateverTheSystemCalendar() throws {
  let noon = try #require(
    WidgetSnapshot.keyCalendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12)))
  var buddhist = Calendar(identifier: .buddhist)
  buddhist.timeZone = .autoupdatingCurrent
  // 佛历下同一天的年份是 2569；若用系统日历拼键，Widget 会找不到主应用写入的公历键。
  #expect(buddhist.component(.year, from: noon) == 2569)
  #expect(WidgetSnapshot.dayKey(for: noon) == "2026-09-25")
  #expect(WidgetSnapshot.monthKey(for: noon) == "2026-09")
  #expect(WidgetSnapshot.dayKey(year: 2026, month: 1, day: 2) == "2026-01-02")

  let day = WidgetSnapshot.CalendarSummary(
    dateKey: "2026-09-25", festivals: [], solarTerm: nil,
    schedule: .holiday, holidayName: "中秋节", twelveStar: "除",
    isEcliptic: true, recommends: [], avoids: [])
  let month = WidgetSnapshot.MonthSummary(
    monthKey: "2026-09", firstWeekday: 2, featureKeys: [], days: [])
  let snapshot = WidgetSnapshot(calendarDays: [day], monthSummaries: [month])
  #expect(snapshot.calendarSummary(for: noon) == day)
  #expect(snapshot.monthSummary(for: noon) == month)
  #expect(snapshot.calendarSummary(for: noon, calendar: buddhist) == nil)
}

@Test func seasonalDayToggleReloadsOnlyDailyCalendar() {
  let previous = WidgetSnapshot()
  var enabled = previous
  enabled.showsSeasonal = true
  #expect(enabled.changedWidgetKinds(from: previous) == [WidgetKind.calendar])
}

@Test func monthCalendarSnapshotRoundTripsAndReloadsItsOwnWidget() throws {
  let previous = WidgetSnapshot()
  let day = WidgetSnapshot.MonthDay(
    dateKey: "2026-09-25", number: 25, subtitle: "中秋节",
    holidayName: "中秋节", isWork: false, isWeekend: false)
  let month = WidgetSnapshot.MonthSummary(
    monthKey: "2026-09", firstWeekday: 2,
    featureKeys: ["holidays", "lunar"], days: [day])
  var snapshot = previous
  snapshot.monthSummaries = [month]

  #expect(snapshot.changedWidgetKinds(from: previous) == [WidgetKind.calendarMonth])
  #expect(
    try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
  let date = try #require(ISO8601DateFormatter().date(from: "2026-08-31T16:00:00Z"))
  var shanghai = Calendar(identifier: .gregorian)
  shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  #expect(snapshot.monthSummary(for: date, calendar: shanghai) == month)
  #expect(snapshot.monthSummary(for: date, calendar: utc) == nil)
  let legacy = Data(
    #"{"aiEnabled":false,"quotas":[],"publicIPEnabled":false,"addresses":[],"language":"system","calendarFirstWeekday":2,"showsLunar":true}"#
      .utf8)
  #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: legacy).monthSummaries == nil)
}

@Test func publicAddressSnapshotKeepsLocationASAndFlagsWithoutBreakingOldData() throws {
  let enriched = Data(
    #"{"family":"v4","ip":"203.0.113.8","countryCode":"CN","city":"上海","region":"上海","cityEnglish":"Shanghai","regionEnglish":"Shanghai","organization":"Example","purityScore":85,"purityGrade":"A","asn":"AS4134","isNative":true,"ipType":"Residential IP","riskFlags":["proxy"]}"#
      .utf8)
  let address = try JSONDecoder().decode(WidgetSnapshot.Address.self, from: enriched)
  let encoded = try JSONEncoder().encode(address)
  let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  #expect(fields["region"] as? String == "上海")
  #expect(fields["cityEnglish"] as? String == "Shanghai")
  #expect(fields["regionEnglish"] as? String == "Shanghai")
  #expect(fields["asn"] as? String == "AS4134")
  #expect(fields["isNative"] as? Bool == true)
  #expect(fields["ipType"] as? String == "Residential IP")
  #expect(fields["riskFlags"] as? [String] == ["proxy"])

  let old = Data(
    #"{"family":"v4","ip":"203.0.113.8","countryCode":"CN","city":null,"organization":null,"purityScore":null,"purityGrade":null}"#
      .utf8)
  #expect(try JSONDecoder().decode(WidgetSnapshot.Address.self, from: old).ip == "203.0.113.8")
}

@Test func tomorrowWorkAnswerDoesNotGuessWithoutHolidayCoverage() {
  #expect(WidgetSnapshot.CalendarSummary.Schedule.work.needsWork == true)
  #expect(WidgetSnapshot.CalendarSummary.Schedule.makeupWork.needsWork == true)
  #expect(WidgetSnapshot.CalendarSummary.Schedule.weekend.needsWork == false)
  #expect(WidgetSnapshot.CalendarSummary.Schedule.holiday.needsWork == false)
  #expect(WidgetSnapshot.CalendarSummary.Schedule.makeupDayOff.needsWork == false)
  #expect(WidgetSnapshot.CalendarSummary.Schedule.dayOff.needsWork == false)
  #expect(WidgetSnapshot.CalendarSummary.Schedule.unknown.needsWork == nil)
}

@Test func todayTokenUsageResetsAtLocalMidnightAndRespectsModuleSwitch() throws {
  let scannedDay = try #require(ISO8601DateFormatter().date(from: "2026-09-24T15:00:00Z"))
  let nextDay = try #require(ISO8601DateFormatter().date(from: "2026-09-24T16:00:00Z"))
  var shanghai = Calendar(identifier: .gregorian)
  shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
  let usage = WidgetSnapshot.DailyTokenUsage(provider: "codex", day: scannedDay, tokens: 12_345)
  var snapshot = WidgetSnapshot(aiEnabled: true, dailyTokens: [usage])

  #expect(snapshot.todayTokens(for: "codex", at: scannedDay, calendar: shanghai) == 12_345)
  #expect(snapshot.todayTokens(for: "codex", at: nextDay, calendar: shanghai) == 0)
  #expect(snapshot.todayTokens(for: "claude", at: scannedDay, calendar: shanghai) == nil)
  let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
  #expect(restored.todayTokens(for: "codex", at: scannedDay, calendar: shanghai) == 12_345)
  snapshot.localUsageEnabled = false
  #expect(snapshot.todayTokens(for: "codex", at: scannedDay, calendar: shanghai) == nil)
  let hidden = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
  #expect(hidden.todayTokens(for: "codex", at: scannedDay, calendar: shanghai) == nil)
  snapshot.localUsageEnabled = true
  snapshot.aiEnabled = false
  #expect(snapshot.todayTokens(for: "codex", at: scannedDay, calendar: shanghai) == nil)
}

@Test func oldWidgetSnapshotDecodesWithoutDailyTokens() throws {
  let legacy = Data(
    #"{"aiEnabled":true,"quotaEnabled":false,"quotas":[{"provider":"codex","kind":"weekly","remainingPercent":50,"resetsAt":null,"fetchedAt":0,"isStale":false}],"publicIPEnabled":false,"addresses":[],"language":"system","calendarFirstWeekday":2,"showsLunar":true}"#
      .utf8)
  let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: legacy)
  #expect(snapshot.todayTokens(for: "codex") == nil)
  #expect(snapshot.currentQuotas().count == 1)
  #expect(snapshot.localUsageEnabled == nil)
  #expect(snapshot.quotaShowsRemaining == nil)
  #expect(snapshot.westernUnits == nil)
  #expect(snapshot.cumulativeTokens == nil)
  #expect(snapshot.quotaProviders == nil)
  #expect(snapshot.visibleCumulativeTokens.isEmpty)
}

@Test func cumulativeTokensKeepTheirScopeAndDoNotResetAtMidnight() throws {
  let now = Date()
  let usage = WidgetSnapshot.TokenUsage(
    provider: "codex", input: 1_000, output: 200, scope: .recentYear)
  var snapshot = WidgetSnapshot(
    aiEnabled: true, dailyTokens: [.init(provider: "codex", day: now, tokens: 50)],
    cumulativeTokens: [usage])
  let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
  #expect(restored.visibleCumulativeTokens == [usage])
  #expect(restored.visibleCumulativeTokens.first?.total == 1_200)
  #expect(restored.todayTokens(for: "codex", at: now.addingTimeInterval(86400)) == 0)
  #expect(restored.visibleCumulativeTokens.first?.scope == .recentYear)
  snapshot.localUsageEnabled = false
  #expect(snapshot.visibleCumulativeTokens.isEmpty)
  snapshot.localUsageEnabled = true
  snapshot.aiEnabled = false
  #expect(snapshot.visibleCumulativeTokens.isEmpty)
  #expect(WidgetSnapshot.TokenUsage.sum([Int.max, 1, -1]) == Int.max)
  #expect(WidgetSnapshot.TokenUsage.sum([-1, 2]) == 2)
  #expect(
    WidgetSnapshot.TokenUsage(provider: "Magpie", input: Int.max, output: 1, scope: .all).total
      == Int.max)
}

@Test func fourQuotaSlotsKeepMissingExpiredAndZeroValuesDistinct() {
  let now = Date()
  func quota(_ provider: String, _ remaining: Double, reset: Date? = nil, kind: String = "weekly")
    -> WidgetSnapshot.Quota
  {
    .init(
      provider: provider, kind: kind, remainingPercent: remaining, resetsAt: reset,
      fetchedAt: now, isStale: false)
  }
  var snapshot = WidgetSnapshot(
    aiEnabled: true,
    quotas: [
      quota("codex", 60, kind: "session"), quota("codex", 0),
      quota("claude", 99, reset: now), quota("gemini", .nan),
    ], quotaProviders: ["codex", "claude", "gemini", "grok"])
  let slots = snapshot.quotaSlots(at: now)
  #expect(slots.map(\.provider) == ["codex", "claude", "gemini", "grok"])
  #expect(slots[0].quota?.remainingPercent == 0)
  #expect(slots.dropFirst().allSatisfy { $0.quota == nil })
  #expect(WidgetSnapshot(aiEnabled: true).quotaSlots(at: now).count == 4)
  snapshot.quotaProviders = ["copilot", "copilot", "custom", "", "claude", "codex", "extra"]
  #expect(snapshot.quotaSlots(at: now).map(\.provider) == ["codex", "claude", "copilot", "custom"])
  snapshot.aiEnabled = false
  #expect(snapshot.quotaSlots(at: now).allSatisfy { $0.quota == nil })
  snapshot.quotaProviders = nil
  snapshot.quotas = [quota("grok", 40), quota("codex", 60)]
  #expect(snapshot.quotaSlots(at: now).map(\.provider) == ["codex", "claude", "gemini", "grok"])
}

@Test func weeklyQuotaResetRingUsesOnlyKnownWeeklyWindows() {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let week: TimeInterval = 7 * 24 * 3600
  for kind in ["7 days", "7d", "weekly", "sonnetWeekly"] {
    for (interval, expected) in [
      (week * 2, 1.0), (week, 1.0), (week / 2, 0.5), (0, 0.0), (-3600, 0.0),
    ] {
      let quota = WidgetSnapshot.Quota(
        provider: "codex", kind: kind, remainingPercent: 20,
        resetsAt: now.addingTimeInterval(interval), fetchedAt: now, isStale: false)
      #expect(quota.weeklyResetFraction(at: now) == expected)
    }
  }
  for kind in ["5 hours", "session", "monthly", "unknown"] {
    let quota = WidgetSnapshot.Quota(
      provider: "custom", kind: kind, remainingPercent: 20,
      resetsAt: now.addingTimeInterval(3600), fetchedAt: now, isStale: false)
    #expect(quota.weeklyResetFraction(at: now) == nil)
  }
  let missing = WidgetSnapshot.Quota(
    provider: "codex", kind: "7 days", remainingPercent: 20,
    resetsAt: nil, fetchedAt: now, isStale: false)
  #expect(missing.weeklyResetFraction(at: now) == nil)
}

@Test func cumulativeSummaryAndSlotChangesReloadTheirOwnWidget() {
  let previous = WidgetSnapshot(aiEnabled: true)
  var current = previous
  current.cumulativeTokens = [
    .init(provider: "Magpie", input: 100, output: 20, scope: .all)
  ]
  #expect(current.changedWidgetKinds(from: previous) == [WidgetKind.todayTokens])
  let fresh = current
  current.cumulativeTokens = [
    .init(provider: "Magpie", input: 100, output: 20, scope: .all, isStale: true)
  ]
  #expect(current.changedWidgetKinds(from: fresh) == [WidgetKind.todayTokens])
  current = previous
  current.quotaProviders = ["claude", "codex"]
  #expect(current.changedWidgetKinds(from: previous) == [WidgetKind.aiQuota])
}

@Test func onlyWidgetsWhoseDisplayedDataChangedAreReloaded() {
  let now = Date()
  func quota(fetchedAt: Date, remaining: Double = 37) -> WidgetSnapshot.Quota {
    .init(
      provider: "codex", kind: "weekly", remainingPercent: remaining,
      resetsAt: now.addingTimeInterval(3600),
      fetchedAt: fetchedAt, isStale: false)
  }
  let address = WidgetSnapshot.Address(
    family: "v4", ip: "203.0.113.1", countryCode: "CN", city: nil,
    organization: nil, purityScore: 82, purityGrade: "A")
  let base = WidgetSnapshot(
    aiEnabled: true, quotas: [quota(fetchedAt: now)],
    dailyTokens: [.init(provider: "codex", day: now, tokens: 10)],
    publicIPEnabled: true, addresses: [address], showsLunar: true)

  // 重新抓取但额度未变：抓取时间不显示在 Widget 上，不应消耗重载预算
  var refetched = base
  refetched.quotas = [quota(fetchedAt: now.addingTimeInterval(1800))]
  #expect(refetched != base)
  #expect(refetched.changedWidgetKinds(from: base).isEmpty)

  var quotaChanged = base
  quotaChanged.quotas = [quota(fetchedAt: now, remaining: 20)]
  #expect(quotaChanged.changedWidgetKinds(from: base) == [WidgetKind.aiQuota])

  var tokensChanged = base
  tokensChanged.dailyTokens = [.init(provider: "codex", day: now, tokens: 11)]
  #expect(tokensChanged.changedWidgetKinds(from: base) == [WidgetKind.todayTokens])

  var localDisabled = base
  localDisabled.localUsageEnabled = false
  #expect(localDisabled.todayTokens(for: "codex", at: now) == nil)
  #expect(localDisabled.changedWidgetKinds(from: base) == [WidgetKind.todayTokens])

  var ipDisabled = base
  ipDisabled.publicIPEnabled = false
  #expect(ipDisabled.changedWidgetKinds(from: base) == [WidgetKind.ipPurity, WidgetKind.publicIP])

  var noAddress = base
  noAddress.addresses = []
  var noAddressDisabled = noAddress
  noAddressDisabled.publicIPEnabled = false
  #expect(
    noAddressDisabled.changedWidgetKinds(from: noAddress) == [
      WidgetKind.ipPurity, WidgetKind.publicIP,
    ])
  #expect(
    noAddress.changedWidgetKinds(from: noAddressDisabled) == [
      WidgetKind.ipPurity, WidgetKind.publicIP,
    ])

  var aiDisabled = base
  aiDisabled.aiEnabled = false
  #expect(
    aiDisabled.changedWidgetKinds(from: base) == [WidgetKind.aiQuota, WidgetKind.todayTokens])

  var lunarHidden = base
  lunarHidden.showsLunar = false
  #expect(
    lunarHidden.changedWidgetKinds(from: base) == [WidgetKind.calendar, WidgetKind.tomorrowWork])

  var relocalized = base
  relocalized.language = "japanese"
  #expect(
    relocalized.changedWidgetKinds(from: base) == [
      WidgetKind.aiQuota, WidgetKind.todayTokens,
      WidgetKind.ipPurity, WidgetKind.publicIP,
      WidgetKind.calendar, WidgetKind.tomorrowWork,
      WidgetKind.calendarMonth, WidgetKind.system,
    ])
}

@Test func displayPreferencesPreserveLegacyDefaultsAndReloadOnlyAffectedWidgets() throws {
  let legacy = WidgetSnapshot()
  var current = legacy
  current.quotaShowsRemaining = true
  current.westernUnits = false
  #expect(current.changedWidgetKinds(from: legacy).isEmpty)
  // 小组件固定显示剩余额度，该偏好只保存在摘要中，不触发重载。
  current.quotaShowsRemaining = false
  #expect(current.changedWidgetKinds(from: legacy).isEmpty)
  current.quotaShowsRemaining = true
  current.westernUnits = true
  #expect(current.changedWidgetKinds(from: legacy) == [WidgetKind.todayTokens])
  let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(current))
  #expect(restored.westernUnits == true)
  #expect(restored.quotaShowsRemaining == true)
}
