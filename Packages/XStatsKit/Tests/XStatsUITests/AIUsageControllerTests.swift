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

private func usageSnapshot(percent: Double, at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> AIUsageSnapshot {
    AIUsageSnapshot(provider: .codex, planName: "Pro 20x",
                    windows: [AIQuotaWindow(kind: .weekly, usedPercent: percent, resetsAt: nil)],
                    remainingCredits: nil, fetchedAt: date)
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
        var snapshot = usageSnapshot(percent: 0, at: now)
        snapshot.localUsage = LocalUsageReport(rows: [ModelTokenUsage(day: Calendar.current.startOfDay(for: now),
            model: "test", input: 100, output: 10)], fileCount: 1)
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
            var value = AIUsageSnapshot(provider: id, planName: nil, windows: [], remainingCredits: nil, fetchedAt: now)
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
        #expect(settings.aiUsageDisplayMode == .remaining)
    }

    @Test func transientFailurePreservesLastGoodSnapshotAsStale() async {
        let provider = StubUsageProvider([.success(usageSnapshot(percent: 72)), .failure(.network)])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let controller = AIUsageController(settings: settings, providers: [provider])

        await controller.refresh()
        await controller.refresh()

        #expect(controller.state(for: .codex).snapshot?.window(.weekly)?.usedPercent == 72)
        #expect(controller.state(for: .codex).failure == .network)
        #expect(controller.state(for: .codex).isStale)
    }

    @Test func authenticationFailureClearsLastGoodSnapshot() async {
        let provider = StubUsageProvider([.success(usageSnapshot(percent: 72)), .failure(.unauthorized)])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let controller = AIUsageController(settings: settings, providers: [provider])

        await controller.refresh()
        await controller.refresh()

        #expect(controller.state(for: .codex).snapshot == nil)
        #expect(controller.state(for: .codex).failure == .unauthorized)
    }

    @Test func rateLimitPreventsRequestsUntilRetryDate() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = StubUsageProvider([.failure(.rateLimited(now.addingTimeInterval(300)))])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let controller = AIUsageController(settings: settings, providers: [provider], now: { now })

        await controller.refresh()
        await controller.refresh()

        #expect(await provider.count() == 1)
        #expect(controller.state(for: .codex).failure == .rateLimited(now.addingTimeInterval(300)))
    }

    @Test func menuBarReadingUsesAttentionWindowAndDisplayMode() async throws {
        let provider = StubUsageProvider([.success(usageSnapshot(percent: 87))])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let controller = AIUsageController(settings: settings, providers: [provider])

        await controller.refresh()
        let reading = try #require(controller.menuBarReading)

        #expect(reading.displayedFraction == 0.13)
        #expect(reading.usedFraction == 0.87)
        #expect(reading.kind == .weekly)
    }

    @Test func disablingTrackingHidesCachedMenuBarReading() async {
        let provider = StubUsageProvider([.success(usageSnapshot(percent: 87))])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let controller = AIUsageController(settings: settings, providers: [provider])
        await controller.refresh()

        settings.aiUsageEnabled = false

        #expect(controller.menuBarReading == nil)
    }

    @Test func fixedWindowNeverFallsBackToAnotherQuota() async {
        let provider = StubUsageProvider([.success(usageSnapshot(percent: 87))])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        settings.aiUsageFocus = .session
        let controller = AIUsageController(settings: settings, providers: [provider])
        await controller.refresh()
        #expect(controller.menuBarReading == nil)
        settings.aiUsageFocus = .weekly
        #expect(controller.menuBarReading?.kind == .weekly)
    }

    @Test func pausedControllerDoesNotFetch() async {
        let provider = StubUsageProvider([.success(usageSnapshot(percent: 87))])
        let settings = AppSettings(defaults: defaultsForAIUsage())
        settings.aiUsageEnabled = true
        let controller = AIUsageController(settings: settings, providers: [provider])
        controller.setPaused(true)
        await controller.refresh()
        #expect(await provider.count() == 0)
    }
}
