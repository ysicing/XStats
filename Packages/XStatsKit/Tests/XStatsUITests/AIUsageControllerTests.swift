// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import AIUsage
import Foundation
import Testing
@testable import XStatsUI

private actor StubUsageProvider: AIUsageProvider {
    nonisolated let id: AIProviderID
    private var results: [Result<AIUsageSnapshot, AIUsageFailure>]
    private(set) var fetchCount = 0

    init(_ results: [Result<AIUsageSnapshot, AIUsageFailure>], id: AIProviderID = .codex) {
        self.results = results; self.id = id
    }

    func fetch() async throws -> AIUsageSnapshot {
        fetchCount += 1
        guard !results.isEmpty else { throw AIUsageFailure.network }
        return try results.removeFirst().get()
    }

    func count() -> Int { fetchCount }
}

private actor StubQuotaProvider: AIQuotaProvider {
    nonisolated let id: AIProviderID
    private var results: [Result<AIQuotaSnapshot, AIQuotaFailure>]
    private(set) var count = 0

    init(id: AIProviderID = .codex, results: [Result<AIQuotaSnapshot, AIQuotaFailure>]) {
        self.id = id
        self.results = results
    }

    func fetch() async throws -> AIQuotaSnapshot {
        count += 1
        return try results.removeFirst().get()
    }

    func fetchCount() -> Int { count }
}

private func defaultsForAIUsage() -> UserDefaults {
    let name = "AIUsageControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func usageSnapshot(tokens: Int, id: AIProviderID = .codex, at date: Date = Date()) -> AIUsageSnapshot {
    var snapshot = AIUsageSnapshot(provider: id, fetchedAt: date)
    snapshot.localUsage = LocalUsageReport(rows: [ModelTokenUsage(day: Calendar.current.startOfDay(for: date),
        model: "test", input: tokens, output: 0, records: 1)], fileCount: 1)
    return snapshot
}

/// 可控闸门：第一次 fetch 会一直卡住，直到测试放行
private actor GatedUsageProvider: AIUsageProvider {
    nonisolated let id = AIProviderID.codex
    private(set) var started = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var open = false

    func fetch() async throws -> AIUsageSnapshot {
        started += 1
        if !open { await withCheckedContinuation { gate = $0 } }
        var snapshot = AIUsageSnapshot(provider: .codex, fetchedAt: Date())
        snapshot.localUsage = LocalUsageReport(rows: [ModelTokenUsage(day: Calendar.current.startOfDay(for: Date()),
            model: "test", input: 100, output: 0, records: 1)], fileCount: 1)
        return snapshot
    }

    func release() { open = true; gate?.resume(); gate = nil }
    func startCount() -> Int { started }
}

@MainActor
@Suite struct AIUsageControllerTests {
    @Test func menuBarShowsBothSubscriptionSourcesAndKeepsWeeklySummary() async {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let codex = AIQuotaSnapshot(provider: .codex, windows: [
            AIQuotaWindow(kind: .session, usedPercent: 95, resetsAt: reset),
            AIQuotaWindow(kind: .weekly, usedPercent: 73, resetsAt: reset),
        ], fetchedAt: Date())
        let claude = AIQuotaSnapshot(provider: .claude, windows: [
            AIQuotaWindow(kind: .weekly, usedPercent: 48, resetsAt: reset),
        ], fetchedAt: Date())
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [
            StubQuotaProvider(results: [.success(codex)]),
            StubQuotaProvider(id: .claude, results: [.success(claude)]),
        ])
        await model.aiUsage.refresh()

        let reading = MenuBarReading(model: model)
        let codexQuota = reading.aiQuotas.first { $0.provider == .codex }
        #expect(codexQuota?.window.kind == .weekly)
        #expect(codexQuota?.remainingPercent == 27)
        #expect(codexQuota?.resetText != "—")
        #expect(reading.aiQuotas.map(\.provider) == [.codex, .claude])
        let both = MenuBarRenderer.image(reading: reading, items: [.aiUsage],
            style: { _ in .stacked }, networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
        var codexOnly = reading
        codexOnly.aiQuotas = reading.aiQuotas.filter { $0.provider == .codex }
        let single = MenuBarRenderer.image(reading: codexOnly, items: [.aiUsage],
            style: { _ in .stacked }, networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
        #expect(both.size.width > single.size.width)
        let codexIcon = MenuBarRenderer.image(reading: codexOnly, items: [.aiUsage],
            style: { _ in .icon }, networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
        var claudeOnly = reading
        claudeOnly.aiQuotas = reading.aiQuotas.filter { $0.provider == .claude }
        let claudeIcon = MenuBarRenderer.image(reading: claudeOnly, items: [.aiUsage],
            style: { _ in .icon }, networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
        #expect(!codexIcon.isTemplate && !claudeIcon.isTemplate)
        #expect(codexIcon.tiffRepresentation != claudeIcon.tiffRepresentation)
        for style in [MenuBarStyle.ring, .pie, .meter, .dot] {
            let bothGraphic = MenuBarRenderer.image(reading: reading, items: [.aiUsage],
                style: { _ in style }, networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
            let singleGraphic = MenuBarRenderer.image(reading: codexOnly, items: [.aiUsage],
                style: { _ in style }, networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
            #expect(bothGraphic.size.width > singleGraphic.size.width)
            #expect(!bothGraphic.isTemplate)
        }
        let tooltip = reading.tooltip(items: [.aiUsage], fahrenheit: false)
        #expect(tooltip.contains("Codex"))
        #expect(tooltip.contains("27%"))
        #expect(tooltip.contains("Claude"))
        #expect(tooltip.contains("52%"))
        #expect(!tooltip.contains("5%"))
    }

    @Test func menuBarOmitsSourceWithoutQuotaBesideTheAvailableOne() async {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let codex = AIQuotaSnapshot(provider: .codex, windows: [
            AIQuotaWindow(kind: .weekly, usedPercent: 50, resetsAt: nil),
        ], fetchedAt: Date())
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [
            StubQuotaProvider(results: [.success(codex)]),
            StubQuotaProvider(id: .claude, results: [.failure(.notConfigured)]),
        ])
        await model.aiUsage.refresh()

        let reading = MenuBarReading(model: model)
        #expect(reading.aiQuotas.map(\.provider) == [.codex])
        #expect(!reading.tooltip(items: [.aiUsage], fahrenheit: false).contains("Claude"))
        let image = MenuBarRenderer.image(reading: reading, items: [.aiUsage],
            style: { _ in .stacked }, networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
        #expect(image.size.width > 0)
    }

    @Test func menuBarLabelsManualQuotaAndOptionalFastWindow() async {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let snapshot = AIQuotaSnapshot(provider: .claude, windows: [
            AIQuotaWindow(kind: .fableWeekly, usedPercent: 40, resetsAt: nil),
        ], fetchedAt: Date(), source: .sub2api)
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [],
                             aiQuotaProviders: [StubQuotaProvider(id: .claude, results: [.success(snapshot)])])
        await model.aiUsage.refresh()

        let reading = MenuBarReading(model: model)
        #expect(reading.aiQuotas.first?.shortWindowName == "7d F")
        #expect(reading.tooltip(items: [.aiUsage], fahrenheit: false).contains("Claude (Sub2API)"))
    }

    @Test func menuBarSkipsQuotaWindowsPastTheirReset() async {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let past = Date().addingTimeInterval(-3600)
        let future = Date().addingTimeInterval(3600)
        let partlyExpired = AIQuotaSnapshot(provider: .codex, windows: [
            AIQuotaWindow(kind: .session, usedPercent: 30, resetsAt: future),
            AIQuotaWindow(kind: .weekly, usedPercent: 95, resetsAt: past),
        ], fetchedAt: past)
        let allExpired = AIQuotaSnapshot(provider: .claude, windows: [
            AIQuotaWindow(kind: .weekly, usedPercent: 95, resetsAt: past),
        ], fetchedAt: past)
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [
            StubQuotaProvider(results: [.success(partlyExpired)]),
            StubQuotaProvider(id: .claude, results: [.success(allExpired)]),
        ])
        await model.aiUsage.refresh()

        let reading = MenuBarReading(model: model)
        // 周窗口已重置，退回仍有效的 5 小时窗口，而不是继续显示过期的 5%。
        #expect(reading.aiQuotas.map(\.provider) == [.codex])
        #expect(reading.aiQuotas.first?.window.kind == .session)
        #expect(reading.aiQuotas.first?.remainingPercent == 70)
        let tooltip = reading.tooltip(items: [.aiUsage], fahrenheit: false)
        #expect(!tooltip.contains("Claude"), "tooltip: \(tooltip)")
        #expect(!tooltip.contains("5%"), "tooltip: \(tooltip)")
    }

    @Test func menuBarFallsBackToLocalTokensWhenSubscriptionIsUnavailable() async {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let model = AppModel(settings: settings, historyURL: nil,
            aiUsageProviders: [StubUsageProvider([.success(usageSnapshot(tokens: 42))])],
            aiQuotaProviders: [StubQuotaProvider(results: [.failure(.notConfigured)])])
        await model.aiUsage.refresh()

        let reading = MenuBarReading(model: model)
        #expect(reading.aiQuotas.isEmpty)
        let tooltip = reading.tooltip(items: [.aiUsage], fahrenheit: false)
        #expect(tooltip.contains("42 Tokens"))
        #expect(!tooltip.contains("剩余"))
    }

    @Test func quotaRefreshFollowsMasterSwitchAndKeepsLocalTokensOnAuthFailure() async {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        let quota = StubQuotaProvider(results: [.failure(.unauthorized)])
        let local = StubUsageProvider([.success(usageSnapshot(tokens: 42))])
        let controller = AIUsageController(settings: settings, providers: [local], quotaProviders: [quota])

        await controller.refresh()
        #expect(await quota.fetchCount() == 0)
        settings.aiUsageEnabled = true
        await controller.refresh()
        #expect(await quota.fetchCount() == 1)
        #expect(controller.todayTokens == 42)
        #expect(controller.quotaState(for: .codex).failure == .unauthorized)
        settings.aiUsageEnabled = false
        #expect(controller.visibleQuotaState(for: .codex).snapshot == nil)
    }

    @Test func quotaTransportFailureKeepsLastValueButLogoutClearsIt() async {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let first = AIQuotaSnapshot(provider: .codex,
            windows: [AIQuotaWindow(kind: .weekly, usedPercent: 63, resetsAt: nil)], fetchedAt: Date())
        let quota = StubQuotaProvider(results: [.success(first), .failure(.network), .failure(.unauthorized)])
        let controller = AIUsageController(settings: settings, providers: [], quotaProviders: [quota])

        await controller.refresh()
        #expect(controller.visibleQuotaState(for: .codex).snapshot?.window(.weekly)?.usedPercent == 63)
        #expect(controller.visibleQuotaProviders(for: nil) == [.codex])
        await controller.refresh()
        #expect(controller.visibleQuotaState(for: .codex).snapshot?.window(.weekly)?.usedPercent == 63)
        #expect(controller.visibleQuotaState(for: .codex).failure == .network)
        #expect(controller.visibleQuotaProviders(for: nil) == [.codex])
        await controller.refresh()
        #expect(controller.visibleQuotaState(for: .codex).snapshot == nil)
        #expect(controller.visibleQuotaState(for: .codex).failure == .unauthorized)
        #expect(controller.visibleQuotaProviders(for: nil) == [.codex])
    }

    @Test func lastSuccessfulQuotaSurvivesRestartAndAuthFailureClearsDiskCache() async {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xstats-quota-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: cacheURL.path + suffix)
            }
        }
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let previous = AIQuotaSnapshot(provider: .codex, windows: [
            AIQuotaWindow(kind: .weekly, usedPercent: 76, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ], fetchedAt: Date(timeIntervalSince1970: 1_799_000_000), source: .sub2api)
        let first = AIUsageController(settings: settings, providers: [],
            quotaProviders: [StubQuotaProvider(results: [.success(previous)])], quotaCacheURL: cacheURL)
        await first.refresh()

        let restored = AIUsageController(settings: settings, providers: [],
            quotaProviders: [StubQuotaProvider(results: [.failure(.network)])], quotaCacheURL: cacheURL)
        #expect(restored.visibleQuotaState(for: .codex).snapshot == previous)
        #expect(restored.visibleQuotaState(for: .codex).isStale)
        await restored.refresh()
        #expect(restored.visibleQuotaState(for: .codex).snapshot == previous)
        #expect(restored.visibleQuotaState(for: .codex).failure == .network)

        let newer = AIQuotaSnapshot(provider: .codex, windows: [
            AIQuotaWindow(kind: .weekly, usedPercent: 81, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ], fetchedAt: Date(timeIntervalSince1970: 1_799_100_000))
        let refreshed = AIUsageController(settings: settings, providers: [],
            quotaProviders: [StubQuotaProvider(results: [.success(newer)])], quotaCacheURL: cacheURL)
        await refreshed.refresh()
        #expect(refreshed.visibleQuotaState(for: .codex).snapshot == newer)
        #expect(!refreshed.visibleQuotaState(for: .codex).isStale)

        let logout = AIUsageController(settings: settings, providers: [],
            quotaProviders: [StubQuotaProvider(results: [.failure(.unauthorized)])], quotaCacheURL: cacheURL)
        await logout.refresh()
        #expect(logout.visibleQuotaState(for: .codex).snapshot == nil)
        let afterLogout = AIUsageController(settings: settings, providers: [],
            quotaProviders: [StubQuotaProvider(results: [.failure(.network)])], quotaCacheURL: cacheURL)
        #expect(afterLogout.visibleQuotaState(for: .codex).snapshot == nil)
    }

    @Test func removingSub2APIClearsItsPersistedQuotaButKeepsDirectOne() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xstats-quota-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: cacheURL.path + suffix)
            }
        }
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let manual = AIQuotaSnapshot(provider: .codex, windows: [
            AIQuotaWindow(kind: .weekly, usedPercent: 60, resetsAt: reset),
        ], fetchedAt: Date(), source: .sub2api)
        let direct = AIQuotaSnapshot(provider: .claude, windows: [
            AIQuotaWindow(kind: .weekly, usedPercent: 30, resetsAt: reset),
        ], fetchedAt: Date())
        func offline() -> AIUsageController {
            AIUsageController(settings: settings, providers: [], quotaProviders: [
                StubQuotaProvider(results: [.failure(.network)]),
                StubQuotaProvider(id: .claude, results: [.failure(.network)]),
            ], quotaCacheURL: cacheURL)
        }

        let online = AIUsageController(settings: settings, providers: [], quotaProviders: [
            StubQuotaProvider(results: [.success(manual)]),
            StubQuotaProvider(id: .claude, results: [.success(direct)]),
        ], quotaCacheURL: cacheURL)
        await online.refresh()
        // 关闭模块：内存清空、磁盘仍保留 Sub2API 快照，此时移除配置必须按磁盘来源清理。
        settings.aiUsageEnabled = false
        online.start()
        online.stop()
        #expect(online.quotaState(for: .codex).snapshot == nil)
        online.clearSub2APIQuota(for: .codex)
        online.clearSub2APIQuota(for: .claude)
        settings.aiUsageEnabled = true
        let restarted = offline()
        #expect(restarted.quotaState(for: .codex).snapshot == nil, "removed Sub2API quota reappeared from disk")
        #expect(restarted.quotaState(for: .claude).snapshot == direct, "direct quota must survive Sub2API removal")

        // 内存是 Sub2API、磁盘是直连（例如上次写缓存失败）：只清内存，保留磁盘上的直连快照。
        let directCodex = AIQuotaSnapshot(provider: .codex, windows: manual.windows, fetchedAt: Date())
        let mixed = AIUsageController(settings: settings, providers: [],
            quotaProviders: [StubQuotaProvider(results: [.success(manual)])], quotaCacheURL: cacheURL)
        await mixed.refresh()
        try AIQuotaCacheStore(url: cacheURL).save(directCodex)
        mixed.clearSub2APIQuota(for: .codex)
        #expect(mixed.quotaState(for: .codex).snapshot == nil)
        #expect(offline().quotaState(for: .codex).snapshot == directCodex)
    }

    @Test func disabledSourceIsNotQueriedForQuota() async {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        settings.aiUsageSources = [.claude]
        let codex = StubQuotaProvider(results: [])
        let claude = StubQuotaProvider(id: .claude, results: [.failure(.notConfigured)])
        let controller = AIUsageController(settings: settings, providers: [], quotaProviders: [codex, claude])

        await controller.refresh()

        #expect(await codex.fetchCount() == 0)
        #expect(await claude.fetchCount() == 1)
        #expect(controller.visibleQuotaState(for: .codex).failure == nil)
    }

    @Test func unconfiguredQuotaIsHiddenWithoutHidingLocalUsageOrOtherQuota() async {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let codexQuota = AIQuotaSnapshot(provider: .codex,
            windows: [AIQuotaWindow(kind: .weekly, usedPercent: 61, resetsAt: nil)], fetchedAt: Date())
        let controller = AIUsageController(settings: settings,
            providers: [StubUsageProvider([.success(usageSnapshot(tokens: 42))])],
            quotaProviders: [
                StubQuotaProvider(results: [.success(codexQuota), .failure(.notConfigured)]),
                StubQuotaProvider(id: .claude, results: [.failure(.notConfigured), .failure(.notConfigured)]),
            ])

        await controller.refresh()
        #expect(controller.visibleQuotaProviders(for: nil) == [.codex])
        #expect(controller.todayTokens == 42)

        await controller.refresh()
        #expect(controller.visibleQuotaProviders(for: nil).isEmpty)
        #expect(controller.todayTokens == 42)
    }

    @Test func sourceSelectionPersistsIncludingAllDisabled() {
        let defaults = defaultsForAIUsage()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.aiUsageSources == [.codex, .claude])
        settings.aiUsageSources = [.claude]
        #expect(AppSettings(defaults: defaults).aiUsageSources == [.claude])
        settings.aiUsageSources = []
        #expect(AppSettings(defaults: defaults).aiUsageSources.isEmpty)
    }

    @Test func disabledSourceIsNotFetchedOrIncludedInReports() async throws {
        let now = Date()
        let snapshot = usageSnapshot(tokens: 110, at: now)
        let codex = StubUsageProvider([.success(snapshot)])
        let claude = StubUsageProvider([.success(snapshot)], id: .claude)
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        settings.aiUsageSources = [.claude]
        let controller = AIUsageController(settings: settings, providers: [codex, claude])
        await controller.refresh()
        #expect(await codex.count() == 0)
        #expect(await claude.count() == 1)
        #expect(controller.todayTokens == 110)
        settings.aiUsageSources = []
        #expect(controller.localReport(for: .claude) == nil)
        #expect(controller.todayTokens == nil)
        await controller.refresh()
        #expect(await claude.count() == 1)
        #expect(controller.state(for: .claude).snapshot == nil)
    }

    @Test func localReportsFilterProvidersAndSumTodayWithoutLosingCacheCreation() async throws {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        func snapshot(_ id: AIProviderID, tokens: Int, created: Int) -> AIUsageSnapshot {
            var value = AIUsageSnapshot(provider: id, fetchedAt: now)
            value.localUsage = LocalUsageReport(rows: [ModelTokenUsage(day: today, model: id.rawValue,
                input: tokens, cached: 20, output: 10, records: 1, cacheCreated: created)], fileCount: 1)
            return value
        }
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let controller = AIUsageController(settings: settings, providers: [
            StubUsageProvider([.success(snapshot(.codex, tokens: 100, created: 0))]),
            StubUsageProvider([.success(snapshot(.claude, tokens: 200, created: 50))], id: .claude)
        ])
        await controller.refresh()
        #expect(controller.todayTokens == 320)
        #expect(LocalUsageReport.total(try #require(controller.localReport(for: .claude)).rows).total == 210)
        #expect(LocalUsageReport.total(try #require(controller.localReport(for: nil)).rows).cacheCreated == 50)
        #expect(controller.localReport(for: nil)?.fileCount == 2)
    }

    @Test func navigationExposesAIUsageAsAMonitorAndMenuBarItem() {
        #expect(PanelTab.monitors.contains(.aiUsage))
        #expect(PanelTab(item: .aiUsage) == .aiUsage)
        #expect(MenuBarStyle.options(for: .aiUsage) == [.stacked, .inline, .icon, .ring, .pie, .meter, .dot])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.menuBarStyle = .history
        #expect(settings.style(for: .aiUsage) == .ring)
        settings.menuBarStyle = .line
        #expect(settings.style(for: .aiUsage) == .ring)
        settings.menuBarStyle = .pie
        #expect(settings.style(for: .aiUsage) == .pie)
    }

    @Test func settingsDefaultToOptInAndThirtyMinuteRefresh() {
        let settings = AppSettings(defaults: defaultsForAIUsage())

        #expect(!settings.aiUsageEnabled)
        #expect(settings.aiUsageRefreshMinutes == 30)
    }

    @Test func disablingAIUsageLeavesItsHiddenPageAndRestoresNavigationOnEnable() {
        let defaults = defaultsForAIUsage()
        let settings = AppSettings(defaults: defaults)

        settings.aiUsageEnabled = true
        settings.panelTab = .aiUsage
        settings.aiUsageEnabled = false

        #expect(settings.panelTab == .settingsGeneral)
        #expect(AppSettings(defaults: defaults).panelTab == .settingsGeneral)

        settings.aiUsageEnabled = true
        settings.panelTab = .aiUsage
        #expect(settings.panelTab == .aiUsage)
    }

    @Test func disabledAIUsageDoesNotRestoreItsSavedPage() {
        let defaults = defaultsForAIUsage()
        defaults.set("aiUsage", forKey: "panelTab")

        #expect(AppSettings(defaults: defaults).panelTab == .settingsGeneral)
    }

    /// 模块开关控制是否读取日志，菜单栏开关只保存展示偏好；模块关闭时不应显示占位图标，
    /// 重新启用后应恢复用户原来的菜单栏选择。
    @Test func menuBarPreferenceDoesNotEnableScanningAndIsRestoredWithTheModule() {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        #expect(!settings.aiUsageEnabled)

        settings.setEnabled(.aiUsage, true)

        #expect(!settings.aiUsageEnabled)
        #expect(settings.isEnabled(.aiUsage))
        #expect(!settings.orderedMenuBarItems.contains(.aiUsage))

        settings.aiUsageEnabled = true
        #expect(settings.orderedMenuBarItems.contains(.aiUsage))

        settings.aiUsageEnabled = false
        #expect(settings.isEnabled(.aiUsage))
        #expect(!settings.orderedMenuBarItems.contains(.aiUsage))
    }

    @Test func transientFailurePreservesLastGoodSnapshotAsStale() async {
        let provider = StubUsageProvider([.success(usageSnapshot(tokens: 72)), .failure(.invalidResponse)])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let controller = AIUsageController(settings: settings, providers: [provider])

        await controller.refresh()
        await controller.refresh()

        #expect(controller.todayTokens == 72)
        #expect(controller.state(for: .codex).failure == .invalidResponse)
        #expect(controller.localState(for: .codex).stale)
    }

    @Test func disablingTrackingHidesCachedLocalReport() async {
        let provider = StubUsageProvider([.success(usageSnapshot(tokens: 87))])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let controller = AIUsageController(settings: settings, providers: [provider])
        await controller.refresh()
        #expect(controller.todayTokens == 87)

        settings.aiUsageEnabled = false

        #expect(controller.todayTokens == nil)
    }

    /// 在途刷新期间到来的刷新必须排队执行，不能被静默丢弃：轮询任务会把那次丢弃当成
    /// “首次刷新已完成”，接着睡满整个周期（最长 60 分钟），而在途那次的结果又会因
    /// generation 变化被丢掉，关掉再打开统计后页面会一直空着。
    @Test func aRefreshArrivingDuringAnotherIsQueuedNotDropped() async throws {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let provider = GatedUsageProvider()
        let controller = AIUsageController(settings: settings, providers: [provider])

        let first = Task { await controller.refresh() }
        while await provider.startCount() == 0 { await Task.yield() }
        let second = Task { await controller.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        await provider.release()
        _ = await (first.value, second.value)

        #expect(await provider.startCount() == 2)
        #expect(controller.todayTokens == 100)
    }

    /// 排队链上的任务是非结构化的，stop() 必须显式取消，否则关掉统计后几十秒的冷扫描还在跑。
    @Test func stopCancelsAnInFlightRefresh() async throws {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let provider = GatedUsageProvider()
        let controller = AIUsageController(settings: settings, providers: [provider])

        let inFlight = Task { await controller.refresh() }
        while await provider.startCount() == 0 { await Task.yield() }
        controller.stop()
        await provider.release()
        await inFlight.value

        // 结果按 generation 变化丢弃，不会写回状态
        #expect(controller.todayTokens == nil)
    }

    /// 系统唤醒会同时发出屏幕唤醒与系统唤醒通知；重复的恢复不能再排一次完整扫描和额度请求。
    @Test func repeatedResumeDoesNotQueueAnotherRefresh() async throws {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let provider = GatedUsageProvider()
        let controller = AIUsageController(settings: settings, providers: [provider])
        defer { controller.stop() }

        controller.setPaused(true)
        controller.setPaused(false)
        while await provider.startCount() == 0 { await Task.yield() }
        controller.setPaused(false)
        await provider.release()
        try await Task.sleep(for: .milliseconds(100))

        #expect(await provider.startCount() == 1)
        #expect(controller.todayTokens == 100)
    }

    @Test func pausedControllerDoesNotFetch() async {
        let provider = StubUsageProvider([.success(usageSnapshot(tokens: 87))])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let controller = AIUsageController(settings: settings, providers: [provider])
        controller.setPaused(true)
        await controller.refresh()
        #expect(await provider.count() == 0)
    }
}
