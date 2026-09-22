// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import AIUsage
import Foundation
import Testing
@testable import XStatsUI

private actor StubUsageProvider: AIUsageProvider {
    nonisolated let id = AIProviderID.codex
    private var results: [Result<AIUsageSnapshot, AIUsageFailure>]
    private(set) var fetchCount = 0

    init(_ results: [Result<AIUsageSnapshot, AIUsageFailure>]) { self.results = results }

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
    @Test func navigationExposesAIUsageAsAMonitorAndMenuBarItem() {
        #expect(PanelTab.monitors.contains(.aiUsage))
        #expect(PanelTab(item: .aiUsage) == .aiUsage)
        #expect(MenuBarStyle.options(for: .aiUsage) == [.stacked, .inline, .icon, .ring, .pie, .meter, .dot])
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
