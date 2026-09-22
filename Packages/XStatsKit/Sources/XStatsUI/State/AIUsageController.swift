// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Foundation
import Observation

public struct AIUsageProviderState: Equatable, Sendable {
    public let provider: AIProviderID
    public var snapshot: AIUsageSnapshot?
    public var failure: AIUsageFailure?
    public var isRefreshing = false

    public init(provider: AIProviderID) { self.provider = provider }
}

/// 本机用量的低频刷新入口。Provider 只负责一次只读扫描；调度与“保留旧值”策略集中在这里。
@MainActor
@Observable
public final class AIUsageController {
    public private(set) var states: [AIProviderID: AIUsageProviderState]
    /// 供 AppController 观察的刷新脉冲；页面上的“上次检查”读的是各 Provider 的 fetchedAt。
    public private(set) var lastAttemptAt: Date?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let providers: [any AIUsageProvider]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var cadenceTask: Task<Void, Never>?
    @ObservationIgnored private var refreshInProgress = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var paused = false

    public init(settings: AppSettings, providers: [any AIUsageProvider] = [CodexLocalUsageProvider(), ClaudeLocalUsageProvider()],
                now: @escaping @Sendable () -> Date = Date.init) {
        self.settings = settings
        self.providers = providers
        self.now = now
        states = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, AIUsageProviderState(provider: $0.id)) })
    }

    public func state(for provider: AIProviderID) -> AIUsageProviderState {
        states[provider] ?? AIUsageProviderState(provider: provider)
    }

    public var isRefreshing: Bool { states.values.contains(where: \.isRefreshing) }

    public var todayTokens: Int? {
        guard settings.aiUsageEnabled, let report = localReport(for: nil) else { return nil }
        return LocalUsageReport.total(report.selected(days: 1, now: now())).total
    }

    public func localReport(for provider: AIProviderID?) -> LocalUsageReport? {
        let reports = states.values.filter { settings.aiUsageSources.contains($0.provider) && (provider == nil || $0.provider == provider) }
            .compactMap { $0.snapshot?.localUsage }
        guard !reports.isEmpty else { return nil }
        return LocalUsageReport(rows: reports.flatMap(\.rows), fileCount: reports.reduce(0) { $0 + $1.fileCount },
                                unreadableFiles: reports.reduce(0) { $0 + $1.unreadableFiles })
    }

    public func localState(for provider: AIProviderID?) -> (stale: Bool, updated: Date?) {
        let selected = states.values.filter { settings.aiUsageSources.contains($0.provider) && (provider == nil || $0.provider == provider) }
        return (selected.contains { $0.failure != nil }, selected.compactMap { $0.snapshot?.fetchedAt }.min())
    }

    public func start() {
        let previousTask = cadenceTask
        previousTask?.cancel()
        cadenceTask = nil
        for provider in providers where !settings.aiUsageSources.contains(provider.id) {
            states[provider.id] = AIUsageProviderState(provider: provider.id)
        }
        guard settings.aiUsageEnabled, !settings.aiUsageSources.isEmpty, !paused else {
            generation += 1
            if !settings.aiUsageEnabled {
                states = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, AIUsageProviderState(provider: $0.id)) })
            }
            return
        }
        let seconds = settings.aiUsageRefreshMinutes * 60
        cadenceTask = Task { [weak self] in
            // 先等旧轮询退出，避免新刷新撞上 refreshInProgress 后睡过整个周期。
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await self?.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    public func stop() {
        generation += 1
        cadenceTask?.cancel()
        cadenceTask = nil
    }

    public func setPaused(_ value: Bool) {
        paused = value
        if value { stop() } else { start() }
    }

    public func refresh() async {
        guard settings.aiUsageEnabled, !paused, !refreshInProgress, !Task.isCancelled else { return }
        refreshInProgress = true
        let currentGeneration = generation
        defer {
            refreshInProgress = false
            for id in states.keys { states[id]?.isRefreshing = false }
        }
        let attempt = now()

        for provider in providers {
            guard settings.aiUsageSources.contains(provider.id) else {
                states[provider.id] = AIUsageProviderState(provider: provider.id)
                continue
            }
            var state = state(for: provider.id)
            state.isRefreshing = true
            states[provider.id] = state
            do {
                let snapshot = try await provider.fetch()
                guard currentGeneration == generation, settings.aiUsageEnabled, !Task.isCancelled else { return }
                guard settings.aiUsageSources.contains(provider.id) else {
                    states[provider.id] = AIUsageProviderState(provider: provider.id)
                    continue
                }
                state.snapshot = snapshot
                state.failure = nil
            } catch let failure as AIUsageFailure {
                guard currentGeneration == generation, settings.aiUsageEnabled, !Task.isCancelled else { return }
                guard settings.aiUsageSources.contains(provider.id) else { continue }
                // 扫描失败不代表日志消失了，保留上一次的统计结果并在页面上标注为旧数据。
                state.failure = failure
            } catch {
                guard currentGeneration == generation, settings.aiUsageEnabled, !Task.isCancelled else { return }
                guard settings.aiUsageSources.contains(provider.id) else { continue }
                state.failure = .network
            }
            state.isRefreshing = false
            states[provider.id] = state
        }
        lastAttemptAt = attempt
    }
}
