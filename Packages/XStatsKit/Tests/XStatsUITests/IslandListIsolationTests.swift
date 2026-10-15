// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import AppKit
import Localization
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct IslandListIsolationTests {
    @Test(arguments: [false, true])
    func expandedListsCanBuildOffMainQueue(nestedQuotas: Bool) async throws {
        let suite = "IslandListIsolationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = await appModel(defaults: defaults)
        defer { app.aiUsage.stop() }
        let model = IslandModel()
        model.presentation = .expanded
        model.scene = .ai
        let view = IslandView(model: model, appModel: app, selectScene: { model.scene = $0 },
                              expand: {}, collapse: {}, stop: {})
        let lists = islandListProbes(in: view.body)
        #expect(lists.count == 2)
        let providers = try #require(lists.last)
        let probes = nestedQuotas ? providers.content.nestedLists() : lists
        #expect(probes.count == 2)

        // 直接调用真实 ForEach.content，模拟 macOS 15 的后台 DisplayLink。
        let counts = await Task.detached { probes.map { $0.content.buildRows() } }.value
        #expect(counts == (nestedQuotas ? [2, 4] : [3, 2]))
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func expandedScenesRenderAfterSelectionAndQuotaChanges(direction: LayoutDirection) async throws {
        _ = NSApplication.shared
        _ = try #require(NSScreen.main)
        let suite = "IslandRenderingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // 初始化前写入隔离偏好，避免 language.didSet 修改进程全局 L10n。
        defaults.set((direction == .rightToLeft ? AppLanguage.arabic : .english).rawValue,
                     forKey: AppSettings.languageKey)
        let app = await appModel(defaults: defaults)
        defer { app.aiUsage.stop() }
        let model = IslandModel()
        model.presentation = .expanded
        let host = NSHostingView(rootView: IslandView(model: model, appModel: app,
            selectScene: { model.scene = $0 }, expand: {}, collapse: {}, stop: {})
            .frame(width: 420, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        for scene in IslandScene.allCases {
            model.scene = scene
            for showsRemaining in [true, false] {
                app.settings.aiQuotaShowsRemaining = showsRemaining
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                #expect(window.isVisible && host.fittingSize == CGSize(width: 420, height: 300))
            }
        }
    }

    private func appModel(defaults: UserDefaults) async -> AppModel {
        let settings = AppSettings(defaults: defaults)
        settings.historyEnabled = false
        settings.enabledAlerts = []
        settings.aiUsageEnabled = true
        settings.aiUsageSources = [.codex, .claude]
        let app = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [
            IslandQuotaFixture(id: .codex, kinds: [.session, .weekly]),
            IslandQuotaFixture(id: .claude, kinds: [.session, .weekly, .opusWeekly, .sonnetWeekly]),
        ])
        await app.aiUsage.refresh()
        return app
    }
}

private struct IslandQuotaFixture: AIQuotaProvider {
    let id: AIProviderID
    let kinds: [AIQuotaKind]

    func fetch() async throws -> AIQuotaSnapshot {
        AIQuotaSnapshot(provider: id, windows: kinds.map { AIQuotaWindow(kind: $0, usedPercent: 25, resetsAt: nil) },
                        fetchedAt: Date())
    }
}

private protocol IslandListContentProbe {
    func buildRows() -> Int
    @MainActor func nestedLists() -> [IslandBackgroundListProbe]
}

extension ForEach: IslandListContentProbe where Content: View {
    fileprivate func buildRows() -> Int {
        #expect(!Thread.isMainThread)
        for element in data { _ = content(element) }
        return data.count
    }

    @MainActor fileprivate func nestedLists() -> [IslandBackgroundListProbe] {
        data.flatMap { islandListProbes(in: content($0).body) }
    }
}

private protocol IslandDeferredListProbe {
    @MainActor var listBody: Any { get }
}

extension MainActorForEach: IslandDeferredListProbe {
    fileprivate var listBody: Any { body }
}

// 仅测试用：跨隔离域传递实际列表回调，以检测旧 SwiftUI 未标注 Sendable 的调用边界。
private struct IslandBackgroundListProbe: @unchecked Sendable {
    let content: any IslandListContentProbe
}

@MainActor private func islandListProbes(in value: Any) -> [IslandBackgroundListProbe] {
    if let list = value as? any IslandDeferredListProbe { return islandListProbes(in: list.listBody) }
    if let content = value as? any IslandListContentProbe { return [IslandBackgroundListProbe(content: content)] }
    return Mirror(reflecting: value).children.flatMap { islandListProbes(in: $0.value) }
}
