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
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
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
        cadenceTask?.cancel()
        cadenceTask = nil
        for provider in providers where !settings.aiUsageSources.contains(provider.id) {
            states[provider.id] = AIUsageProviderState(provider: provider.id)
        }
        guard settings.aiUsageEnabled, !settings.aiUsageSources.isEmpty, !paused else {
            generation += 1
            // 不再轮询时，在途的冷扫描也没有意义了
            refreshTask?.cancel(); refreshTask = nil
            if !settings.aiUsageEnabled {
                states = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, AIUsageProviderState(provider: $0.id)) })
            }
            return
        }
        let seconds = settings.aiUsageRefreshMinutes * 60
        cadenceTask = Task { [weak self] in
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
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func setPaused(_ value: Bool) {
        paused = value
        if value { stop() } else { start() }
    }

    /// 刷新串行排队。旧实现遇到在途刷新就直接返回，而轮询任务把这次返回当成“首次刷新已完成”，
    /// 接着睡满整个周期（最长 60 分钟）；那次在途刷新的结果又会因 generation 变化被丢弃，
    /// 于是关掉再打开统计后页面会一直空着。链上的任务是非结构化的，stop() 必须显式取消它。
    public func refresh() async {
        let previous = refreshTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.performRefresh()
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        guard settings.aiUsageEnabled, !paused, !Task.isCancelled else { return }
        let currentGeneration = generation
        defer {
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
