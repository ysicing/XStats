// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import AIUsage
import Foundation
import AppKit
import Localization
import SwiftUI
import Testing
import WidgetData
@testable import XStatsUI

/// 其他模块的测试不应访问开发机正在运行的 Magpie。
struct UnavailableMagpieClient: MagpieFetching {
  func quotas() async throws -> [MagpieQuota] { throw MagpieFailure.unavailable }
  func usage(period: MagpiePeriod) async throws -> MagpieUsageSummary {
    throw MagpieFailure.unavailable
  }
}

private actor MagpieStub: MagpieFetching {
  private var quotaPayload: Data?
  private var failing = false
  private var gate: CheckedContinuation<Void, Never>?
  private var gated = false
  private(set) var quotaCalls = 0
  private(set) var periods: [MagpiePeriod] = []

  init(quotaPayload: Data? = nil) { self.quotaPayload = quotaPayload }

  func fail(_ value: Bool) { failing = value }
  func setQuotaPayload(_ value: Data) { quotaPayload = value }
  func hold() { gated = true }
  func release() {
    gated = false
    gate?.resume()
    gate = nil
  }
  func counts() -> (Int, [MagpiePeriod]) { (quotaCalls, periods) }

  func quotas() async throws -> [MagpieQuota] {
    quotaCalls += 1
    if gated { await withCheckedContinuation { gate = $0 } }
    if failing { throw MagpieFailure.unavailable }
    if let quotaPayload { return try MagpieClient.decodeQuotas(quotaPayload) }
    return try MagpieClient.decodeQuotas(
      Data(
        #"{"object":"list","data":[{"provider":"grok","name":"first","kind":"subscription","windows":[{"name":"7 days","used":32,"remaining":68}]},{"provider":"codex","name":"other","kind":"subscription","windows":[{"name":"7 days","used":90,"remaining":10}]},{"provider":"codex","name":"active","kind":"subscription","last":true,"windows":[{"name":"7 days","used":4,"remaining":96}]}]}"#
          .utf8))
  }

  func usage(period: MagpiePeriod) async throws -> MagpieUsageSummary {
    periods.append(period)
    if failing { throw MagpieFailure.unavailable }
    return try MagpieClient.decodeUsage(
      Data(
        "{\"period\":\"\(period.rawValue)\",\"bucket\":\"hour\",\"input\":100,\"output\":20,\"calls\":1,\"cost\":0.25,\"models\":[],\"series\":[]}"
          .utf8), period: period)
  }
}

private final class MagpieTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date()
  func read() -> Date { lock.withLock { date } }
  func nextDay() {
    lock.withLock { date = Calendar.current.date(byAdding: .day, value: 1, to: date)! }
  }
}

@MainActor
struct MagpieControllerTests {
  @Test func connectionGuidanceUsesInstallationOnlyAfterAnAPIFailure() {
    let app = URL(fileURLWithPath: "/Applications/magpie.app")
    #expect(
      MagpieInstallation.Guidance.resolve(
        application: app, commandLineInstalled: false, previouslyConnected: false) == .launch(app))
    #expect(
      MagpieInstallation.Guidance.resolve(
        application: nil, commandLineInstalled: false, previouslyConnected: false) == .install)
    #expect(
      MagpieInstallation.Guidance.resolve(
        application: nil, commandLineInstalled: true, previouslyConnected: false) == .retry)
    #expect(
      MagpieInstallation.Guidance.resolve(
        application: nil, commandLineInstalled: false, previouslyConnected: true) == .retry)
  }

  @Test func unavailableMagpiePageFitsBothLayoutDirections() async {
    let model = AppModel(
      settings: settings(), historyURL: nil, magpieClient: UnavailableMagpieClient())
    model.aiUsage.cumulativeWidgetIsInstalled = { false }
    await model.aiUsage.refresh()
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let host = NSHostingView(
        rootView: AIUsagePopover().environment(model).environment(\.layoutDirection, direction))
      host.frame = NSRect(x: 0, y: 0, width: 360, height: 360)
      host.layoutSubtreeIfNeeded()
      #expect(host.fittingSize.width <= 360)
      #expect(host.fittingSize.height.isFinite)
    }
    model.aiUsage.stop()
  }

  @Test func displayPreferencesInvalidateOnlyRelevantMenuBarImages() async {
    let settings = settings()
    let model = AppModel(settings: settings, historyURL: nil, magpieClient: MagpieStub())
    model.aiUsage.cumulativeWidgetIsInstalled = { false }
    await model.aiUsage.refresh()
    let remaining = MenuBarReading(model: model)
    settings.aiQuotaShowsRemaining = false
    let used = MenuBarReading(model: model)
    #expect(!used.aiQuotaShowsRemaining)
    #expect(!used.hasSameImage(as: remaining, item: .aiUsage, style: .stacked))
    #expect(used.hasSameImage(as: remaining, item: .cpu, style: .stacked))
    #expect(used.aiQuotas.first?.remainingPercent == 10)
    var tokens = remaining
    tokens.aiQuotas = []
    tokens.aiTokens = 123_456
    var western = tokens
    western.aiUsageWesternUnits = true
    #expect(!western.hasSameImage(as: tokens, item: .aiUsage, style: .stacked))
  }

  @Test func unavailableMagpieDoesNotExposeTokenOrQuotaValues() async {
    let controller = AIUsageController(
      settings: settings(), magpieClient: UnavailableMagpieClient())
    controller.cumulativeWidgetIsInstalled = { false }
    await controller.refresh()
    #expect(controller.magpieQuotaFailure == .unavailable)
    #expect(controller.magpieUsageFailures[.daily] == .unavailable)
    #expect(controller.todayTokens == nil)
    #expect(controller.menuBarMagpieQuotas().isEmpty)
    #expect(controller.lastAttemptAt != nil)
    #expect(!controller.isRefreshing)
  }

  @Test func refreshArrivingDuringAnotherRunsAfterIt() async throws {
    let magpie = MagpieStub()
    await magpie.hold()
    let controller = AIUsageController(settings: settings(), magpieClient: magpie)
    controller.cumulativeWidgetIsInstalled = { false }
    let first = Task { await controller.refresh() }
    let deadline = ContinuousClock.now + .seconds(2)
    while await magpie.counts().0 == 0, ContinuousClock.now < deadline { await Task.yield() }
    let started = await magpie.counts().0 == 1
    let second = Task { await controller.refresh() }
    await magpie.release()
    await first.value
    await second.value
    #expect(started)
    #expect(await magpie.counts().0 == 2)
    #expect(await magpie.counts().1 == [.daily, .daily])
    #expect(controller.todayTokens == 120)
  }

  @Test func magpieRefreshSynchronizesWidgetIncludingStaleFailure() async throws {
    let suite = "MagpieWidget.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.aiUsageEnabled = true
    settings.aiUsageShowsLocalUsage = true
    settings.aiMenuBarProviders = ["codex", "claude", "gemini", "grok"]
    settings.setAIMenuBarProviderOrder(["codex", "claude", "gemini", "grok"])
    let magpie = MagpieStub()
    let model = AppModel(
      settings: settings, historyURL: nil,
      magpieClient: magpie)
    model.aiUsage.cumulativeWidgetIsInstalled = { true }
    defer { model.aiUsage.stop() }
    let store = WidgetSnapshotStore(defaults: defaults)
    let app = AppController(model: model, widgetStore: store, reloadWidget: { _ in })
    app.syncWidgetSnapshot()
    app.observeWidgetState()
    await model.aiUsage.refresh()
    try await waitForWidget { !store.load().quotas.isEmpty }
    #expect(store.load().dailyTokens?.first?.tokens == 120)
    #expect(store.load().visibleCumulativeTokens.first?.total == 120)
    #expect(store.load().visibleCumulativeTokens.first?.scope == .all)
    #expect(store.load().quotaSlots().map(\.provider) == ["codex", "grok", "claude", "gemini"])
    #expect(store.load().quotas.allSatisfy { !$0.isStale })
    let accounts = try #require(store.load().quotaAccounts)
    let codex = accounts.filter { $0.provider == "codex" }
    #expect(codex.count == 2)
    // last:true 是最近服务标记，Widget 默认跟随 Magpie 返回的首个账号。
    #expect(store.load().quotaSlots().first?.quota?.remainingPercent == 10)
    settings.aiPreferredAccounts["codex"] = codex[1].id
    settings.aiWidgetShowsResetRing = true
    try await waitForWidget { store.load().preferredQuotaAccounts?["codex"] == codex[1].id }
    #expect(store.load().quotaSlots().first?.quota?.remainingPercent == 96)
    #expect(store.load().quotaShowsResetRing == true)
    #expect(AppSettings(defaults: defaults).aiPreferredAccounts["codex"] == codex[1].id)
    settings.aiPreferredAccounts["codex"] = "removed"
    try await waitForWidget { store.load().preferredQuotaAccounts?["codex"] == "removed" }
    #expect(store.load().quotaSlots().first?.quota == nil)
    #expect(model.aiUsage.magpieQuotaReadings().allSatisfy { $0.sourceName != "codex" })
    settings.aiPreferredAccounts["codex"] = codex[1].id
    try await waitForWidget { store.load().preferredQuotaAccounts?["codex"] == codex[1].id }
    await magpie.fail(true)
    await model.aiUsage.refresh()
    try await waitForWidget { store.load().quotas.contains { $0.isStale } }
    #expect(store.load().quotas.allSatisfy { $0.isStale })
    #expect(store.load().visibleCumulativeTokens.first?.isStale == true)
    #expect(store.load().visibleCumulativeTokens.first?.total == 120)
  }

  @Test func providerReorderSynchronizesWidgetWithoutRefreshingMagpie() async throws {
    let suite = "MagpieWidgetOrder.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.aiUsageEnabled = true
    settings.aiMenuBarProviders = ["claude", "codex", "grok", "workbuddy"]
    let magpie = MagpieStub()
    let model = AppModel(settings: settings, historyURL: nil, magpieClient: magpie)
    defer { model.aiUsage.stop() }
    await model.aiUsage.refresh()
    let calls = await magpie.counts()
    let store = WidgetSnapshotStore(defaults: defaults)
    var reloaded: [String] = []
    let app = AppController(
      model: model, widgetStore: store, reloadWidget: { reloaded.append($0) })
    app.syncWidgetSnapshot()
    app.observeWidgetState()
    #expect(store.load().quotaSlots().map(\.provider) == ["codex", "grok", "claude", "workbuddy"])
    reloaded.removeAll()
    let order = ["workbuddy", "grok", "codex", "claude"]
    #expect(settings.setAIMenuBarProviderOrder(order))
    try await waitForWidget {
      store.load().quotaSlots().map(\.provider) == ["grok", "codex", "workbuddy", "claude"]
    }
    #expect(store.load().quotaSlots().first { $0.provider == "workbuddy" }?.quota == nil)
    #expect(reloaded == [WidgetKind.aiQuota])
    #expect(
      model.aiUsage.menuBarMagpieQuotas().map(\.sourceName)
        == order.filter { provider in
          model.aiUsage.magpieQuotaReadings().contains { $0.sourceName == provider }
        })
    #expect(await magpie.counts().0 == calls.0)
    #expect(await magpie.counts().1 == calls.1)
    settings.aiMenuBarProviders.remove("workbuddy")
    try await waitForWidget { store.load().quotaProviders?.contains("workbuddy") == false }
    #expect(store.load().quotaSlots().count == 4)
  }

  @Test func widgetDefaultBrandsDoNotDisplaceExistingMagpieServices() async throws {
    let payload = Data(
      """
      {"object":"list","data":[
        {"provider":"codex","name":"A","kind":"subscription","windows":[{"name":"7 days","remaining":60}]},
        {"provider":"claude","name":"B","kind":"subscription","windows":[{"name":"7 days","remaining":70}]},
        {"provider":"kimi","name":"C","kind":"subscription","windows":[{"name":"7 days","remaining":80}]}
      ]}
      """.utf8)
    let suite = "MagpieWidgetCandidates.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.aiUsageEnabled = true
    let magpie = MagpieStub(quotaPayload: payload)
    let model = AppModel(settings: settings, historyURL: nil, magpieClient: magpie)
    defer { model.aiUsage.stop() }
    await model.aiUsage.refresh()
    let store = WidgetSnapshotStore(defaults: defaults)
    let app = AppController(model: model, widgetStore: store, reloadWidget: { _ in })
    app.syncWidgetSnapshot()
    let slots = store.load().quotaSlots()
    #expect(slots.map(\.provider) == ["claude", "codex", "kimi", "grok"])
    #expect(slots.compactMap(\.quota).count == 3)
    let failedPayload = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
    var accounts = try #require(failedPayload?["data"] as? [[String: Any]])
    accounts[0]["error"] = "unavailable"
    accounts[0]["windows"] = []
    await magpie.setQuotaPayload(
      try JSONSerialization.data(withJSONObject: ["object": "list", "data": accounts]))
    await model.aiUsage.refresh()
    app.syncWidgetSnapshot()
    #expect(store.load().quotaSlots().map(\.provider) == slots.map(\.provider))
    #expect(store.load().quotaSlots()[1].quota == nil)
    await magpie.fail(true)
    await model.aiUsage.refresh()
    app.syncWidgetSnapshot()
    #expect(store.load().quotaSlots().map(\.provider) == slots.map(\.provider))
  }

  @Test func deletedPreferredAccountReturnsToMagpieOnlyAfterSuccessfulRefresh() async throws {
    let suite = "MagpieDeletedPreference.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.aiUsageEnabled = true
    settings.aiUsageShowsLocalUsage = false
    let client = MagpieStub()
    let model = AppModel(settings: settings, historyURL: nil, magpieClient: client)
    defer { model.aiUsage.stop() }
    await model.aiUsage.refresh()
    let selected = try #require(
      model.aiUsage.widgetQuotaAccounts(at: .now).first { $0.name == "active" })
    settings.aiPreferredAccounts["codex"] = selected.id
    let store = WidgetSnapshotStore(defaults: defaults)
    let app = AppController(model: model, widgetStore: store, reloadWidget: { _ in })
    app.observeWidgetState()
    await client.setQuotaPayload(
      Data(
        #"{"object":"list","data":[{"provider":"codex","name":"other","kind":"subscription","windows":[{"name":"7 days","remaining":10}]}]}"#
          .utf8))
    await client.fail(true)
    await model.aiUsage.refresh()
    #expect(settings.aiPreferredAccounts["codex"] == selected.id)
    await client.fail(false)
    // 账号仍在但额度读取失败，不能误判为删除。
    await client.setQuotaPayload(
      Data(
        #"{"object":"list","data":[{"provider":"codex","name":"active","kind":"subscription","error":"unavailable","windows":[]}]}"#
          .utf8))
    await model.aiUsage.refresh()
    #expect(settings.aiPreferredAccounts["codex"] == selected.id)
    await client.setQuotaPayload(
      Data(
        #"{"object":"list","data":[{"provider":"codex","name":"other","kind":"subscription","windows":[{"name":"7 days","remaining":10}]}]}"#
          .utf8))
    await model.aiUsage.refresh()
    #expect(settings.aiPreferredAccounts.isEmpty)
    #expect(AppSettings(defaults: defaults).aiPreferredAccounts.isEmpty)
    try await waitForWidget {
      store.load().preferredQuotaAccounts == [:]
        && store.load().quotaSlots().first { $0.provider == "codex" }?.quota?.remainingPercent == 10
    }
    #expect(model.aiUsage.magpieQuotaReadings().first?.remainingPercent == 10)
    let remaining = try #require(model.aiUsage.widgetQuotaAccounts(at: .now).first)
    settings.aiPreferredAccounts["codex"] = remaining.id
    await client.setQuotaPayload(Data(#"{"object":"list","data":[]}"#.utf8))
    await model.aiUsage.refresh()
    #expect(settings.aiPreferredAccounts.isEmpty)
  }

  @Test func widgetSelectsQuotaUsingCurrentTimeInsteadOfMidnight() async throws {
    let calendar = CalendarEngine.gregorian()
    let today = calendar.startOfDay(for: .now)
    let now = today.addingTimeInterval(11 * 3600)
    let expired = today.addingTimeInterval(9 * 3600).ISO8601Format()
    let valid = today.addingTimeInterval(17 * 3600).ISO8601Format()
    let payload = Data(
      """
      {"object":"list","data":[{"provider":"codex","name":"fixture","kind":"subscription","windows":[
        {"name":"7 days","remaining":10,"resetsAt":"\(expired)"},
        {"name":"5 hours","remaining":70,"resetsAt":"\(valid)"}
      ]}]}
      """.utf8)
    let suite = "MagpieWidgetClock.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.aiUsageEnabled = true
    let model = AppModel(
      settings: settings, historyURL: nil,
      magpieClient: MagpieStub(quotaPayload: payload))
    defer { model.aiUsage.stop() }
    await model.aiUsage.refresh()
    let store = WidgetSnapshotStore(defaults: defaults)
    let app = AppController(model: model, widgetStore: store, reloadWidget: { _ in })
    app.syncWidgetSnapshot(now: now)
    #expect(store.load().currentQuotas(at: now).map(\.kind) == ["5 hours"])
    #expect(store.load().currentQuotas(at: now).first?.remainingPercent == 70)
  }

  @Test func widgetAccountIdentityIgnoresAliasAndSeparatesRemoteSources() async throws {
    let payload = Data(
      """
      {"object":"list","data":[
        {"provider":"workbuddy","name":"old","user":"same@example.invalid","alias":"First","kind":"subscription","windows":[]},
        {"provider":"workbuddy","name":"new","user":"same@example.invalid","alias":"Renamed","kind":"subscription","windows":[]},
        {"provider":"workbuddy","name":"new","user":"same@example.invalid","from":"remote","kind":"subscription","windows":[]}
      ]}
      """.utf8)
    let controller = AIUsageController(
      settings: settings(), magpieClient: MagpieStub(quotaPayload: payload))
    defer { controller.stop() }
    await controller.refresh()
    let accounts = controller.widgetQuotaAccounts(at: .now)
    #expect(accounts.count == 3)
    #expect(accounts[0].id == accounts[1].id)
    #expect(accounts[0].id != accounts[2].id)
    #expect(accounts[0].name == "First")
    #expect(accounts[1].name == "Renamed")
    #expect(accounts[2].name.contains("remote"))
    #expect(accounts.allSatisfy { $0.quota == nil })
  }

  @Test func preferredAccountLabelsIncludePlansWithoutChangingSavedIdentity() async throws {
    let payload = Data(
      """
      {"object":"list","data":[
        {"provider":"codex","name":"subscription","user":"same@example.invalid","kind":"subscription","plan":"Plus","windows":[]},
        {"provider":"codex","name":"api","user":"same@example.invalid","kind":"api","plan":"Pro","windows":[]},
        {"provider":"codex","name":"remote","user":"same@example.invalid","from":"Remote Mac","kind":"subscription","plan":"   ","windows":[]}
      ]}
      """.utf8)
    let client = MagpieStub(quotaPayload: payload)
    let settings = settings()
    let controller = AIUsageController(settings: settings, magpieClient: client)
    defer { controller.stop() }
    await controller.refresh()
    let accounts = controller.widgetQuotaAccounts(at: .now)
    let options = zip(accounts, controller.magpieQuotas).map {
      MagpiePreferredAccountOption(account: $0, quota: $1)
    }
    #expect(options[0].title == "same@example.invalid · Plus")
    #expect(options[1].title == "same@example.invalid · Pro")
    #expect(options[2].title == "same@example.invalid · Remote Mac")
    #expect(options.map(\.id) == accounts.map(\.id))
    settings.aiPreferredAccounts["codex"] = options[0].id
    await client.setQuotaPayload(
      Data(
        String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "Plus", with: "Max").utf8)
    )
    await controller.refresh()
    #expect(settings.aiPreferredAccounts["codex"] == controller.widgetQuotaAccounts(at: .now)[0].id)
    let upgraded = MagpiePreferredAccountOption(
      account: controller.widgetQuotaAccounts(at: .now)[0], quota: controller.magpieQuotas[0])
    #expect(upgraded.title == "same@example.invalid · Max")
  }

  @Test func preferredAccountLabelsDisambiguateMatchingPlansAndAliases() throws {
    let quotas = try MagpieClient.decodeQuotas(
      Data(
        """
        {"object":"list","data":[
          {"provider":"codex","name":"first","alias":"Work","user":"first@example.invalid","kind":"subscription","plan":"Pro","windows":[]},
          {"provider":"codex","name":"second","alias":"Work","user":"second@example.invalid","kind":"api","plan":"Pro","windows":[]}
        ]}
        """.utf8))
    let options = quotas.enumerated().map { index, quota in
      MagpiePreferredAccountOption(
        account: .init(id: "\(index)", provider: quota.provider, name: quota.alias!, quota: nil),
        quota: quota)
    }
    #expect(options[0].menuTitle(among: options).contains("subscription"))
    #expect(options[0].menuTitle(among: options).contains("first@example.invalid"))
    #expect(options[1].menuTitle(among: options).contains("api"))
    #expect(options[1].menuTitle(among: options).contains("second@example.invalid"))
  }

  @Test func preferredSubscriptionAccountMovesFirstWithoutReorderingOthers() throws {
    let quotas = try MagpieClient.decodeQuotas(
      Data(
        """
        {"object":"list","data":[
          {"provider":"codex","name":"first","kind":"subscription","windows":[]},
          {"provider":"codex","name":"second","kind":"subscription","windows":[]},
          {"provider":"codex","name":"third","kind":"subscription","windows":[]}
        ]}
        """.utf8))
    let options = quotas.enumerated().map { index, quota in
      MagpiePreferredAccountOption(
        account: .init(id: "\(index)", provider: quota.provider, name: quota.name, quota: nil),
        quota: quota)
    }
    #expect(
      MagpiePreferredAccountOption.ordered(options, preferredID: nil).map(\.id) == ["0", "1", "2"])
    #expect(
      MagpiePreferredAccountOption.ordered(options, preferredID: "2").map(\.id) == ["2", "0", "1"])
    #expect(
      MagpiePreferredAccountOption.ordered(options, preferredID: "1").map(\.id) == ["1", "0", "2"])
    #expect(
      MagpiePreferredAccountOption.ordered(options, preferredID: "removed").map(\.id)
        == ["0", "1", "2"])
    #expect(
      MagpiePreferredAccountOption.ordered([options[0], options[1], options[1]], preferredID: "1")
        .map(\.id) == ["0", "1", "1"])
    #expect(MagpiePreferredAccountOption.ordered([], preferredID: "2").isEmpty)

    let settings = settings()
    let subscriptions = MagpieQuotaAccounts(accounts: options, settings: settings)
    let picker = MagpiePreferredAccounts(account: options[0], options: options, settings: settings)
    #expect(picker.selection.wrappedValue == "0")
    #expect(settings.aiPreferredAccounts.isEmpty)
    picker.selection.wrappedValue = "2"
    #expect(settings.aiPreferredAccounts["codex"] == "2")
    #expect(subscriptions.visibleAccounts.map(\.id) == ["2", "0", "1"])
    picker.selection.wrappedValue = ""
    #expect(settings.aiPreferredAccounts.isEmpty)
    #expect(picker.selection.wrappedValue == "0")
    #expect(subscriptions.visibleAccounts.map(\.id) == ["0", "1", "2"])
  }

  @Test(arguments: [360.0, 640.0], [LayoutDirection.leftToRight, .rightToLeft])
  func preferredAccountLayoutFitsLongNames(width: Double, direction: LayoutDirection) throws {
    var records: [[String: Any]] = []
    for provider in ["codex", "workbuddy", "workbuddy-ai"] {
      for kind in ["subscription", "api"] {
        records.append([
          "provider": provider, "name": "Demo",
          "user": "long.demo.account.for.layout@example.invalid", "kind": kind,
          "plan": kind == "api" ? "Pro" : "self_serve_business_prolite", "windows": [],
        ])
      }
    }
    let quotas = try MagpieClient.decodeQuotas(
      JSONSerialization.data(withJSONObject: ["object": "list", "data": records]))
    let options = quotas.enumerated().map { index, quota in
      MagpiePreferredAccountOption(
        account: .init(id: "\(index)", provider: quota.provider, name: quota.user!, quota: nil),
        quota: quota)
    }
    let settings = settings()
    settings.aiPreferredAccounts["workbuddy"] = options[2].id
    settings.aiQuotaSelectedProvider = "workbuddy"
    let host = NSHostingView(
      rootView: Card { MagpieQuotaAccounts(accounts: options, settings: settings) }
        .environment(\.layoutDirection, direction).padding(16).frame(width: width))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: host.fittingSize),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    #expect(abs(host.fittingSize.width - width) < 0.5)
    #expect(host.fittingSize.height.isFinite)
    #expect(settings.aiPreferredAccounts["workbuddy"] == options[2].id)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let directory = ProcessInfo.processInfo.environment["XSTATS_MAGPIE_PREVIEW_DIR"],
      let png = bitmap.representation(using: .png, properties: [:])
    {
      let suffix = direction == .leftToRight ? "ltr" : "rtl"
      try png.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent("preferred-accounts-\(Int(width))-\(suffix).png"))
    }
  }

  private func waitForWidget(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }

  private func settings() -> AppSettings {
    let settings = AppSettings(
      defaults: UserDefaults(suiteName: "MagpieControllerTests.\(UUID().uuidString)")!)
    settings.aiUsageEnabled = true
    return settings
  }

  @Test func menuBarChoicesIncludeDefaultsSavedAndReturnedServicesAcrossRefreshFailure()
    async throws
  {
    let payload = Data(
      #"{"object":"list","data":[{"provider":"codex","name":"first","kind":"subscription","windows":[]},{"provider":"codex","name":"second","kind":"subscription","windows":[]},{"provider":"claude","name":"account","kind":"subscription","error":"unavailable","windows":[]},{"provider":"grok","name":"account","kind":"subscription","windows":[]},{"provider":"workbuddy-ai","name":"account","kind":"subscription","windows":[]}]}"#
        .utf8)
    let settings = settings()
    settings.aiMenuBarProviders = ["codex", "saved-provider"]
    let selection = settings.aiMenuBarProviders
    let magpie = MagpieStub(quotaPayload: payload)
    let controller = AIUsageController(settings: settings, magpieClient: magpie)
    defer { controller.stop() }
    #expect(
      controller.availableMenuBarQuotaProviders == [
        "codex", "claude", "gemini", "grok", "saved-provider",
      ])
    await controller.refresh()
    #expect(
      controller.availableMenuBarQuotaProviders == [
        "codex", "claude", "gemini", "grok", "saved-provider", "workbuddy-ai",
      ])
    await magpie.fail(true)
    await controller.refresh()
    #expect(controller.magpieQuotaFailure == .unavailable)
    #expect(
      controller.availableMenuBarQuotaProviders == [
        "codex", "claude", "gemini", "grok", "saved-provider", "workbuddy-ai",
      ])
    #expect(settings.aiMenuBarProviders == selection)
  }

  @Test func upgradedInstallWithoutSavedSelectionUsesFourDefaults() async throws {
    let providers = ["perplexity", "copilot", "grok", "gemini", "codex", "claude"]
    let accounts = providers.map {
      [
        "provider": $0, "name": "account", "kind": "subscription",
        "windows": [["name": "7 days", "remaining": 42]],
      ] as [String: Any]
    }
    let payload = try JSONSerialization.data(withJSONObject: ["object": "list", "data": accounts])
    let name = "MagpieControllerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    // 旧版保存过菜单栏项但没有服务选择。
    defaults.set(["cpu", "aiUsage"], forKey: "menuBarItems")
    defaults.set(true, forKey: "aiUsageEnabled")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.aiMenuBarProviders == ["codex", "claude", "gemini", "grok"])
    let controller = AIUsageController(
      settings: settings, magpieClient: MagpieStub(quotaPayload: payload))
    defer { controller.stop() }
    await controller.refresh()
    #expect(settings.aiMenuBarProviders == ["codex", "claude", "gemini", "grok"])
    #expect(
      Set(controller.menuBarMagpieQuotas().map(\.sourceName)) == [
        "codex", "claude", "gemini", "grok",
      ])
    #expect(
      AppSettings(defaults: defaults).aiMenuBarProviders == ["codex", "claude", "gemini", "grok"])
  }

  @Test func menuBarShowsAtMostFourSelectedServicesWithoutLimitingWidgetOrRequestingAgain()
    async throws
  {
    let providers = [
      "copilot", "gemini", "grok", "claude", "codex", "perplexity", "future-provider",
    ]
    let accounts = providers.map {
      [
        "provider": $0, "name": "account", "kind": "subscription",
        "windows": [["name": "7 days", "remaining": 42]],
      ] as [String: Any]
    }
    let payload = try JSONSerialization.data(withJSONObject: ["object": "list", "data": accounts])
    let settings = settings()
    settings.aiUsageShowsLocalUsage = false
    let magpie = MagpieStub(quotaPayload: payload)
    let model = AppModel(
      settings: settings, historyURL: nil,
      magpieClient: magpie)
    defer { model.aiUsage.stop() }
    await model.aiUsage.refresh()
    #expect(
      model.aiUsage.menuBarMagpieQuotas().map(\.sourceName) == [
        "claude", "codex", "grok", "gemini",
      ])
    settings.aiMenuBarProviders = Set(providers)
    let all = MenuBarReading(model: model, items: [.aiUsage])
    #expect(all.aiQuotas.count == 4)
    #expect(all.aiQuotas.map(\.sourceName) == ["claude", "codex", "grok", "gemini"])
    settings.aiMenuBarProviders = ["copilot", "future-provider"]
    let selected = MenuBarReading(model: model, items: [.aiUsage])
    #expect(selected.aiQuotas.map(\.sourceName) == ["copilot", "future-provider"])
    #expect(settings.setAIMenuBarProviderOrder(["future-provider", "copilot"]))
    let reordered = MenuBarReading(model: model, items: [.aiUsage])
    #expect(reordered.aiQuotas.map(\.sourceName) == ["future-provider", "copilot"])
    #expect(!selected.hasSameImage(as: reordered, item: .aiUsage, style: .icon))
    settings.setEnabled(.aiUsage, true)
    settings.trio = TrioConfiguration(outer: .none, center: .none, footer: .aiUsage)
    #expect(TrioReading(model: model).aiDots.map(\.name) == ["future-provider", "copilot"])
    #expect(model.aiUsage.magpieQuotaReadings().count == 7)
    #expect(model.aiUsage.magpieQuotas.count == 7)
    #expect(await magpie.counts().0 == 1)
    for style in MenuBarStyle.allCases {
      let full = MenuBarRenderer.image(
        reading: all, items: [.aiUsage], style: { _ in style },
        networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
      let partial = MenuBarRenderer.image(
        reading: selected, items: [.aiUsage], style: { _ in style },
        networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
      #expect(full.size.width > partial.size.width)
    }
    settings.aiMenuBarProviders = []
    #expect(model.aiUsage.menuBarMagpieQuotas().isEmpty)
    #expect(model.aiUsage.magpieQuotaReadings().count == 7)
  }

  @Test func overviewFollowsSavedQuotaProviderIndependentlyOfMenuBarSelection() async throws {
    let payload = Data(
      #"{"object":"list","data":[{"provider":"claude","name":"first","kind":"subscription","windows":[{"name":"7 days","remaining":20}]},{"provider":"workbuddy","name":"second","kind":"subscription","windows":[{"name":"credits","remaining":95}]},{"provider":"workbuddy-ai","name":"third","kind":"subscription","windows":[{"name":"7 days","remaining":62}]},{"provider":"unavailable","name":"fourth","kind":"subscription","error":"unavailable","windows":[]}]}"#
        .utf8)
    let settings = settings()
    settings.aiUsageShowsLocalUsage = false
    settings.aiMenuBarProviders = ["claude"]
    let magpie = MagpieStub(quotaPayload: payload)
    let model = AppModel(
      settings: settings, historyURL: nil,
      magpieClient: magpie)
    defer { model.aiUsage.stop() }
    await model.aiUsage.refresh()
    for (provider, remaining, window) in [
      ("workbuddy", 95.0, "credits"), ("workbuddy-ai", 62.0, "7 days"),
      ("claude", 20.0, "7 days"),
    ] {
      settings.aiQuotaSelectedProvider = provider
      for showsRemaining in [false, true] {
        settings.aiQuotaShowsRemaining = showsRemaining
        let reading = OverviewReading(item: .aiUsage, model: model)
        #expect(reading.detail.hasPrefix(provider + " · " + window + " · "))
        #expect(
          reading.value
            == AIUsageFormat.quotaPercent(
              remainingPercent: remaining, showsRemaining: showsRemaining,
              locale: L10n.locale, compact: true))
        if case .level(let fraction, _) = reading.chart {
          #expect(abs(fraction - (showsRemaining ? remaining : 100 - remaining) / 100) < 0.0001)
        } else {
          Issue.record("Selected quota must have a progress indicator")
        }
      }
    }
    // 所选服务尚在列表但额度不可用时，不展示其他服务的百分比。
    settings.aiQuotaSelectedProvider = "unavailable"
    let unavailable = OverviewReading(item: .aiUsage, model: model)
    #expect(unavailable.value == "—")
    #expect(!unavailable.hasChart)
    // 服务暂时缺席时与详情页一样展示首项，但保留选择等待它恢复。
    settings.aiQuotaSelectedProvider = "missing"
    #expect(OverviewReading(item: .aiUsage, model: model).detail.hasPrefix("claude · "))
    #expect(settings.aiQuotaSelectedProvider == "missing")
    #expect(settings.aiMenuBarProviders == ["claude"])
    #expect(await magpie.counts().0 == 1)
  }

  @Test func trioFooterKeepsSelectedServicesAndIndependentRemainingQuota() async throws {
    let payload = Data(
      #"{"object":"list","data":[{"provider":"codex","name":"a","kind":"subscription","windows":[{"name":"7 days","remaining":100}]},{"provider":"claude","name":"b","kind":"subscription","windows":[{"name":"7 days","remaining":50}]},{"provider":"gemini","name":"c","kind":"subscription","windows":[{"name":"7 days","remaining":0}]}]}"#
        .utf8)
    let settings = settings()
    settings.menuBarLayout = .iconOnly
    settings.trio = TrioConfiguration(outer: .none, center: .none, footer: .aiUsage)
    let magpie = MagpieStub(quotaPayload: payload)
    let model = AppModel(
      settings: settings, historyURL: nil,
      magpieClient: magpie)
    defer { model.aiUsage.stop() }
    await model.aiUsage.refresh()
    let reading = TrioReading(model: model)
    #expect(reading.aiDots.map(\.name) == ["claude", "codex", "grok", "gemini"])
    #expect(reading.aiDots.map(\.fraction) == [0.5, 1, nil, 0])
    #expect(TrioReading(model: model).aiDots == reading.aiDots)
    settings.aiMenuBarProviders = ["claude", "unavailable-service"]
    let selected = TrioReading(model: model)
    #expect(selected.aiDots.map(\.name) == ["claude", "unavailable-service"])
    #expect(selected.aiDots.map(\.fraction) == [0.5, nil])
    #expect(await magpie.counts().0 == 1)
    settings.aiUsageEnabled = false
    #expect(TrioReading(model: model).aiDots.isEmpty)
  }

  @Test func selectedUnavailableQuotasStayHiddenWithoutSwitchingAccounts() async throws {
    let payload = Data(
      #"{"object":"list","data":[{"provider":"codex","name":"recent","kind":"subscription","last":true,"error":"unavailable","windows":[]},{"provider":"codex","name":"other","kind":"subscription","windows":[{"name":"7 days","remaining":73}]},{"provider":"claude","name":"expired","kind":"subscription","windows":[{"name":"7 days","remaining":80,"resetsAt":"2000-01-01T00:00:00Z"}]},{"provider":"grok","name":"unlimited","kind":"subscription","windows":[{"name":"7 days","unlimited":true}]},{"provider":"gemini","name":"missing","kind":"subscription","windows":[{"name":"7 days"}]}]}"#
        .utf8)
    let settings = settings()
    settings.aiUsageShowsLocalUsage = false
    let controller = AIUsageController(
      settings: settings, magpieClient: MagpieStub(quotaPayload: payload))
    defer { controller.stop() }
    await controller.refresh()
    let quotas = controller.menuBarMagpieQuotas()
    #expect(quotas.isEmpty)
    #expect(settings.aiMenuBarProviders.count == 4)
  }

  @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft], [320.0, 1200.0])
  func menuBarServiceSelectionFitsANarrowSettingsPage(
    direction: LayoutDirection, width: Double
  ) async throws {
    let providers = AIServiceBrand.menuBarOrder + ["future-provider-with-a-long-service-name"]
    let payload = try JSONSerialization.data(withJSONObject: [
      "object": "list",
      "data": providers.map {
        ["provider": $0, "name": "account", "kind": "subscription", "windows": []] as [String: Any]
      },
    ])
    let model = AppModel(
      settings: settings(), historyURL: nil,
      magpieClient: MagpieStub(quotaPayload: payload))
    defer { model.aiUsage.stop() }
    model.settings.aiMenuBarProviders = [
      "codex", "claude", "grok", "future-provider-with-a-long-service-name",
    ]
    await model.aiUsage.refresh()
    let host = NSHostingView(
      rootView: AIQuotaMenuBarSelection().environment(model)
        .environment(\.layoutDirection, direction).environment(\.colorScheme, .light)
        .padding(16).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
    let size = host.fittingSize
    #expect(size.width == width && size.height > 40 && size.height < 500)
    // 截图仅用于人工核对布局；未指定目录时不挂载窗口，也不依赖固定等待。
    guard
      let directory = ProcessInfo.processInfo.environment["XSTATS_AI_MENU_SELECTION_PREVIEW_DIR"]
    else { return }
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.orderFrontRegardless()
    // 系统懒网格在挂载窗口后创建实际控件，截图需等这一轮布局完成。
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let png = bitmap.representation(using: .png, properties: [:]) {
      let path = URL(fileURLWithPath: directory).appendingPathComponent(
        "selection-\(Int(width))-\(direction == .leftToRight ? "ltr" : "rtl").png")
      try png.write(to: path)
    }
  }

  @Test func magpieProvidesTokensAndQuotasIncludingGrok() async throws {
    let settings = settings()
    let magpie = MagpieStub()
    let model = AppModel(
      settings: settings, historyURL: nil,
      magpieClient: magpie)
    await model.aiUsage.refresh()
    #expect(model.aiUsage.todayTokens == 120)
    #expect(model.aiUsage.magpieQuotas.count == 3)
    let reading = MenuBarReading(model: model, items: [.aiUsage])
    #expect(reading.aiQuotas.first(where: { $0.sourceName == "codex" })?.remainingPercent == 10)
    #expect(reading.aiQuotas.first(where: { $0.sourceName == "grok" })?.remainingPercent == 68)
    let image = MenuBarRenderer.image(
      reading: reading, items: [.aiUsage], style: { _ in .icon }, networkStyle: .dots,
      colorizeHighLoad: false, fahrenheit: false)
    #expect(image.size.width > 0)
  }

  @Test func failureKeepsStaleMagpieDataWithoutFallingBack() async {
    let settings = settings()
    let magpie = MagpieStub()
    let controller = AIUsageController(
      settings: settings, magpieClient: magpie)
    await controller.refresh()
    await magpie.fail(true)
    await controller.refresh()
    #expect(controller.magpieQuotaFailure == .unavailable)
    #expect(controller.magpieUsageFailures[.daily] == .unavailable)
    #expect(controller.todayTokens == 120)
    #expect(controller.menuBarMagpieQuotas().allSatisfy { $0.isStale })
    await magpie.fail(false)
    await controller.refresh()
    #expect(controller.magpieQuotaFailure == nil)
    #expect(controller.magpieUsageFailures.isEmpty)
  }

  @Test func periodSelectionFetchesOnlyTodayAndChosenPeriod() async {
    let settings = settings()

    let magpie = MagpieStub()
    let controller = AIUsageController(settings: settings, magpieClient: magpie)
    controller.cumulativeWidgetIsInstalled = { false }
    await controller.selectMagpiePeriod(.weekly)
    let counts = await magpie.counts()
    #expect(Set(counts.1) == [.daily, .weekly])
    #expect(controller.magpieUsage[.weekly]?.total == 120)
  }

  @Test func cumulativeWidgetRequestsOnlyOneExtraSummaryAndStopsWhenRemoved() async {
    let settings = settings()
    let magpie = MagpieStub()
    let controller = AIUsageController(settings: settings, magpieClient: magpie)
    controller.cumulativeWidgetIsInstalled = { true }
    await controller.selectMagpiePeriod(.cumulative)
    #expect(await magpie.counts().1 == [.daily, .cumulative])
    await controller.selectMagpiePeriod(.weekly)
    #expect(await magpie.counts().1 == [.daily, .cumulative, .daily, .weekly, .cumulative])
    controller.cumulativeWidgetIsInstalled = { false }
    await controller.refresh()
    #expect(Array(await magpie.counts().1.suffix(2)) == [.daily, .weekly])
  }

  @Test func pauseDuringWidgetDemandCheckDoesNotStartMagpieRequests() async throws {
    let settings = settings()
    let magpie = MagpieStub()
    let controller = AIUsageController(settings: settings, magpieClient: magpie)
    var demand: CheckedContinuation<Bool, Never>?
    controller.cumulativeWidgetIsInstalled = {
      await withCheckedContinuation { demand = $0 }
    }
    let refresh = Task { await controller.refresh() }
    let deadline = ContinuousClock.now + .seconds(2)
    while demand == nil, ContinuousClock.now < deadline { await Task.yield() }
    controller.setPaused(true)
    let continuation = try #require(demand)
    continuation.resume(returning: true)
    await refresh.value
    #expect(await magpie.counts().0 == 0)
    #expect(await magpie.counts().1.isEmpty)
  }

  @Test func tokenToggleStopsUsageRequestsButKeepsQuota() async {
    let settings = settings()
    settings.aiUsageShowsLocalUsage = false
    let magpie = MagpieStub()
    let controller = AIUsageController(settings: settings, magpieClient: magpie)
    controller.cumulativeWidgetIsInstalled = {
      Issue.record("Disabled Token statistics must not query Widget configurations")
      return true
    }
    await controller.refresh()
    let counts = await magpie.counts()
    #expect(counts.0 == 1)
    #expect(counts.1.isEmpty)
    #expect(controller.todayTokens == nil)
  }

  @Test func disabledAndPausedDoNotRequestMagpie() async {
    let settings = settings()
    let magpie = MagpieStub()
    let controller = AIUsageController(settings: settings, magpieClient: magpie)
    settings.aiUsageEnabled = false
    await controller.refresh()
    settings.aiUsageEnabled = true
    controller.setPaused(true)
    await controller.refresh()
    #expect(await magpie.counts().0 == 0)
  }

  @Test func stoppedRefreshCannotPublishLateResults() async {
    let settings = settings()
    let magpie = MagpieStub()
    await magpie.hold()
    let controller = AIUsageController(settings: settings, magpieClient: magpie)
    let refresh = Task { await controller.refresh() }
    while await magpie.counts().0 == 0 { await Task.yield() }
    controller.stop()
    await magpie.release()
    await refresh.value
    #expect(controller.magpieQuotas.isEmpty)
    #expect(controller.todayTokens == nil)
    #expect(!controller.isRefreshing)
  }
  @Test func nativePopoverRendersInBothLayoutDirections() async throws {
    let settings = settings()

    let model = AppModel(
      settings: settings, historyURL: nil,
      magpieClient: MagpieStub())
    await model.aiUsage.refresh()
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let host = NSHostingView(
        rootView: PopoverFrame(width: 380) {
          PopoverHeader(item: .aiUsage).environment(\.layoutDirection, direction)
        } content: {
          AIUsagePopover().environment(\.layoutDirection, direction)
        }.environment(model)
          .environment(\.isSnapshot, true))
      let size = host.fittingSize
      #expect(size.width == 380 && size.height > 100)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .aqua)
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
      if let directory = ProcessInfo.processInfo.environment["XSTATS_MAGPIE_PREVIEW_DIR"],
        let png = bitmap.representation(using: .png, properties: [:])
      {
        let path = URL(fileURLWithPath: directory).appendingPathComponent(
          direction == .leftToRight ? "magpie-ltr.png" : "magpie-rtl.png")
        try png.write(to: path)
      }
      window.close()
    }
    model.aiUsage.stop()
  }

  @Test(arguments: [
    ["grok", "codex", "copilot"],
    ["claude", "gemini", "perplexity"],
    ["workbuddy", "workbuddy-ai"],
    ["claude", "gemini", "perplexity", "grok", "codex", "copilot", "future-provider"],
  ])
  func nativeProviderPickerKeepsIconsAndMapsRapidSelections(providers: [String]) throws {
    let originalLogoSize = LogoCache.shared.image(named: "site-openai", template: true)?.size
    var selected = try #require(providers.first)
    let binding = Binding(get: { selected }, set: { selected = $0 })
    let host = NSHostingView(
      rootView: MagpieProviderPicker(providers: providers, selection: binding)
        .padding(10).background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: host.fittingSize),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    var views: [NSView] = [host]
    var control: NSSegmentedControl?
    while let view = views.popLast() {
      if let segmented = view as? NSSegmentedControl {
        control = segmented
        break
      }
      views.append(contentsOf: view.subviews)
    }
    let picker = try #require(control)
    // 三个服务在 380pt 弹出页的卡片内能同时容纳图标和完整名称。
    if providers.count == 3 { #expect(picker.intrinsicContentSize.width <= 316) }
    #expect(picker.segmentCount == providers.count)
    for index in providers.indices {
      if let name = AIServiceBrand.logoName(providers[index]) {
        #expect(LogoCache.shared.image(named: name, template: true) != nil)
      }
      #expect(picker.image(forSegment: index) != nil)
      #expect(picker.label(forSegment: index) == AIServiceBrand.title(providers[index]))
    }
    if let directory = ProcessInfo.processInfo.environment["XSTATS_MAGPIE_PREVIEW_DIR"],
      let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
    {
      host.cacheDisplay(in: host.bounds, to: bitmap)
      if let png = bitmap.representation(using: .png, properties: [:]) {
        let filename = "magpie-provider-tabs-\(providers.joined(separator: "-")).png"
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
      }
    }
    for index in Array(providers.indices) + Array(providers.indices.reversed()) {
      picker.selectedSegment = index
      #expect(picker.sendAction(picker.action, to: picker.target))
      #expect(selected == providers[index])
    }
    // 桥接控件必须使用图标副本，不能缩小页面/菜单栏共用的缓存资源。
    #expect(LogoCache.shared.image(named: "site-openai", template: true)?.size == originalLogoSize)
  }

  @Test func quotaProviderChoiceSurvivesReopeningAndTemporaryAbsence() throws {
    let name = "MagpieQuotaSelectionTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let stages: [([String], Int)] = [
      (["claude", "grok", "codex"], 0),
      (["claude", "grok", "codex"], 2),
      (["codex", "claude", "grok"], 0),
      (["claude", "grok"], 0),
      ([], -1),
      (["claude", "grok", "codex"], 2),
    ]
    for (stage, entry) in stages.enumerated() {
      let (providers, expectedSegment) = entry
      let records = providers.map {
        ["provider": $0, "name": "Demo", "kind": "subscription", "windows": []] as [String: Any]
      }
      let accounts = try MagpieClient.decodeQuotas(
        JSONSerialization.data(withJSONObject: ["object": "list", "data": records]))
      let options = accounts.enumerated().map { index, quota in
        MagpiePreferredAccountOption(
          account: .init(id: "\(index)", provider: quota.provider, name: quota.name, quota: nil),
          quota: quota)
      }
      // 每轮重建偏好、模型和页面，覆盖关窗重开及应用重启后的恢复。
      let model = AppModel(
        settings: AppSettings(defaults: defaults), historyURL: nil,
        magpieClient: UnavailableMagpieClient())
      defer { model.aiUsage.stop() }
      let host = NSHostingView(
        rootView: MagpieQuotaAccounts(accounts: options, settings: model.settings).environment(
          model
        )
        .environment(\.isSnapshot, true).frame(width: 600))
      _ = host.fittingSize
      host.layoutSubtreeIfNeeded()
      var views: [NSView] = [host]
      var control: NSSegmentedControl?
      while let view = views.popLast() {
        if let picker = view as? NSSegmentedControl {
          control = picker
          break
        }
        views.append(contentsOf: view.subviews)
      }
      if providers.isEmpty {
        #expect(control == nil)
      } else {
        let picker = try #require(control)
        #expect(picker.selectedSegment == expectedSegment)
        if stage == 0 {
          picker.selectedSegment = 2
          #expect(picker.sendAction(picker.action, to: picker.target))
        }
      }
      #expect(defaults.string(forKey: "aiQuotaSelectedProvider") == "codex")
    }
  }

  @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
  func manyQuotaProvidersRenderAtPopoverWidth(direction: LayoutDirection) throws {
    let providers = [
      "claude", "gemini", "perplexity", "grok", "codex", "copilot",
      "unknown-provider-with-a-long-name",
    ]
    var records: [[String: Any]] = providers.map {
      [
        "provider": $0, "name": "Demo account", "kind": "subscription",
        "windows": [["name": "7 days", "used": 28, "remaining": 72]],
      ]
    }
    records[0]["user"] = "long.demo.account.for.layout@example.invalid"
    records[0]["plan"] = "self_serve_business_prolite"
    records[0]["until"] = "2099-11-01T00:00:00Z"
    records[0]["resets"] = [
      "count": 2, "until": "2099-10-20T12:00:00Z",
      "each": [["until": "2099-10-20T12:00:00Z"], ["until": "2099-11-20T12:00:00Z"]],
    ]
    records.append([
      "provider": "claude", "name": "Second demo account", "kind": "subscription",
      "user": "second.demo@example.invalid", "resets": ["count": 0], "windows": [],
    ])
    let accounts = try MagpieClient.decodeQuotas(
      JSONSerialization.data(withJSONObject: ["object": "list", "data": records]))
    let options = accounts.enumerated().map { index, quota in
      MagpiePreferredAccountOption(
        account: .init(id: "\(index)", provider: quota.provider, name: quota.name, quota: nil),
        quota: quota)
    }
    let model = AppModel(
      settings: settings(), historyURL: nil, magpieClient: UnavailableMagpieClient())
    let host = NSHostingView(
      rootView: Card { MagpieQuotaAccounts(accounts: options, settings: model.settings) }
        .environment(model).environment(\.layoutDirection, direction)
        .environment(\.isSnapshot, true)
        .padding(16).frame(width: 380))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: host.fittingSize),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.close()
      model.aiUsage.stop()
    }
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width == 380)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let directory = ProcessInfo.processInfo.environment["XSTATS_MAGPIE_PREVIEW_DIR"],
      let png = bitmap.representation(using: .png, properties: [:])
    {
      let filename =
        direction == .leftToRight
        ? "magpie-many-providers-ltr.png" : "magpie-many-providers-rtl.png"
      try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
    }
  }

  @Test func revisitingFreshPeriodDoesNotRepeatRequests() async {
    let controller = AIUsageController(
      settings: settings(), magpieClient: MagpieStub())
    await controller.selectMagpiePeriod(.weekly)
    let attempt = controller.lastAttemptAt
    await controller.selectMagpiePeriod(.weekly)
    #expect(controller.lastAttemptAt == attempt)
  }

  @Test func yesterdayIsNotRepublishedAsTodaysTokens() async {
    let clock = MagpieTestClock()
    let controller = AIUsageController(
      settings: settings(), magpieClient: MagpieStub(), now: clock.read)
    await controller.refresh()
    #expect(controller.todayTokens == 120)
    clock.nextDay()
    #expect(controller.todayTokens == nil)
    #expect(controller.magpieSummary(for: .daily) == nil)
  }

}
