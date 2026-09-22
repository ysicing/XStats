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

@MainActor
@Suite struct AIUsageControllerTests {
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
        #expect(MenuBarStyle.options(for: .aiUsage) == [.stacked, .inline, .icon])
    }

    @Test func settingsDefaultToOptInAndThirtyMinuteRefresh() {
        let settings = AppSettings(defaults: defaultsForAIUsage())

        #expect(!settings.aiUsageEnabled)
        #expect(settings.aiUsageRefreshMinutes == 30)
    }

    /// 菜单栏项是这个统计最自然的发现入口。开了却不扫描，用户只会看到一个
    /// 永远不解释自己的 “AI —”，所以打开菜单栏项要一并打开扫描。
    @Test func enablingTheMenuBarItemAlsoTurnsScanningOn() {
        let settings = AppSettings(defaults: defaultsForAIUsage())
        #expect(!settings.aiUsageEnabled)

        settings.setEnabled(.aiUsage, true)

        #expect(settings.aiUsageEnabled)
        #expect(settings.isEnabled(.aiUsage))
        // 其他指标不应该有这种副作用
        settings.aiUsageEnabled = false
        settings.setEnabled(.cpu, true)
        #expect(!settings.aiUsageEnabled)
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
