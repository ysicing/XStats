// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import AIUsage
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import XStatsUI

private actor MagpieStub: MagpieFetching {
    private var failing = false
    private var gate: CheckedContinuation<Void, Never>?
    private var gated = false
    private(set) var quotaCalls = 0
    private(set) var periods: [MagpiePeriod] = []

    func fail(_ value: Bool) { failing = value }
    func hold() { gated = true }
    func release() { gated = false; gate?.resume(); gate = nil }
    func counts() -> (Int, [MagpiePeriod]) { (quotaCalls, periods) }

    func quotas() async throws -> [MagpieQuota] {
        quotaCalls += 1
        if gated { await withCheckedContinuation { gate = $0 } }
        if failing { throw MagpieFailure.unavailable }
        return try MagpieClient.decodeQuotas(Data(#"{"object":"list","data":[{"provider":"grok","name":"first","kind":"subscription","windows":[{"name":"7 days","used":32,"remaining":68}]},{"provider":"codex","name":"other","kind":"subscription","windows":[{"name":"7 days","used":90,"remaining":10}]},{"provider":"codex","name":"active","kind":"subscription","last":true,"windows":[{"name":"7 days","used":4,"remaining":96}]}]}"#.utf8))
    }

    func usage(period: MagpiePeriod) async throws -> MagpieUsageSummary {
        periods.append(period)
        if failing { throw MagpieFailure.unavailable }
        return try MagpieClient.decodeUsage(Data("{\"period\":\"\(period.rawValue)\",\"bucket\":\"hour\",\"input\":100,\"output\":20,\"calls\":1,\"cost\":0.25,\"models\":[],\"series\":[]}".utf8), period: period)
    }
}

private actor UnexpectedLocalReader: AIUsageProvider, AIQuotaProvider {
    nonisolated let id = AIProviderID.codex
    private(set) var calls = 0
    func fetch() async throws -> AIUsageSnapshot { calls += 1; throw AIUsageFailure.network }
    func fetch() async throws -> AIQuotaSnapshot { calls += 1; throw AIQuotaFailure.network }
    func count() -> Int { calls }
}

private final class MagpieTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func read() -> Date { lock.withLock { date } }
    func nextDay() { lock.withLock { date = Calendar.current.date(byAdding: .day, value: 1, to: date)! } }
}

@MainActor
struct MagpieControllerTests {
    private func settings() -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "MagpieControllerTests.\(UUID().uuidString)")!)
        settings.aiUsageEnabled = true
        return settings
    }

    @Test func magpieReplacesAllDirectReadersAndSupportsGrok() async throws {
        let settings = settings()
        let magpie = MagpieStub()
        let direct = UnexpectedLocalReader()
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [direct], aiQuotaProviders: [direct], magpieClient: magpie)
        await model.aiUsage.refresh()
        #expect(await direct.count() == 0)
        #expect(model.aiUsage.todayTokens == 120)
        #expect(model.aiUsage.localReport(for: nil) == nil)
        #expect(model.aiUsage.visibleQuotaProviders(for: nil).isEmpty)
        #expect(model.aiUsage.magpieQuotas.count == 3)
        let reading = MenuBarReading(model: model, items: [.aiUsage])
        #expect(reading.aiQuotas.first(where: { $0.sourceName == "codex" })?.remainingPercent == 96)
        #expect(reading.aiQuotas.first(where: { $0.sourceName == "grok" })?.remainingPercent == 68)
        let image = MenuBarRenderer.image(reading: reading, items: [.aiUsage], style: { _ in .icon }, networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
        #expect(image.size.width > 0)
    }

    @Test func failureKeepsStaleMagpieDataWithoutFallingBack() async {
        let settings = settings()
        let magpie = MagpieStub()
        let direct = UnexpectedLocalReader()
        let controller = AIUsageController(settings: settings, providers: [direct], quotaProviders: [direct], magpieClient: magpie)
        await controller.refresh()
        await magpie.fail(true)
        await controller.refresh()
        #expect(controller.magpieQuotaFailure == .unavailable)
        #expect(controller.magpieUsageFailures[.daily] == .unavailable)
        #expect(controller.todayTokens == 120)
        #expect(controller.menuBarMagpieQuotas().allSatisfy { $0.isStale })
        #expect(await direct.count() == 0)
        await magpie.fail(false)
        await controller.refresh()
        #expect(controller.magpieQuotaFailure == nil)
        #expect(controller.magpieUsageFailures.isEmpty)
    }

    @Test func periodSelectionFetchesOnlyTodayAndChosenPeriod() async {
        let settings = settings()
        settings.aiUsageSources = []
        let magpie = MagpieStub()
        let controller = AIUsageController(settings: settings, providers: [], magpieClient: magpie)
        await controller.selectMagpiePeriod(.weekly)
        let counts = await magpie.counts()
        #expect(Set(counts.1) == [.daily, .weekly])
        #expect(controller.magpieUsage[.weekly]?.total == 120)
    }

    @Test func tokenToggleStopsUsageRequestsButKeepsQuota() async {
        let settings = settings()
        settings.aiUsageShowsLocalUsage = false
        let magpie = MagpieStub()
        let controller = AIUsageController(settings: settings, providers: [], magpieClient: magpie)
        await controller.refresh()
        let counts = await magpie.counts()
        #expect(counts.0 == 1)
        #expect(counts.1.isEmpty)
        #expect(controller.todayTokens == nil)
    }

    @Test func disabledAndPausedDoNotRequestMagpie() async {
        let settings = settings()
        let magpie = MagpieStub()
        let controller = AIUsageController(settings: settings, providers: [], magpieClient: magpie)
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
        let controller = AIUsageController(settings: settings, providers: [], magpieClient: magpie)
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
        settings.aiUsageSources = [] // Magpie 独立于本地数据源开关，顶部刷新仍须可用。
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [], magpieClient: MagpieStub())
        await model.aiUsage.refresh()
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let host = NSHostingView(rootView: PopoverFrame(width: 380) {
                PopoverHeader(item: .aiUsage).environment(\.layoutDirection, direction)
            } content: {
                AIUsagePopover().environment(\.layoutDirection, direction)
            }.environment(model)
                .environment(\.isSnapshot, true))
            let size = host.fittingSize
            #expect(size.width == 380 && size.height > 100)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            if let directory = ProcessInfo.processInfo.environment["XSTATS_MAGPIE_PREVIEW_DIR"],
               let png = bitmap.representation(using: .png, properties: [:]) {
                let path = URL(fileURLWithPath: directory).appendingPathComponent(direction == .leftToRight ? "magpie-ltr.png" : "magpie-rtl.png")
                try png.write(to: path)
            }
            window.close()
        }
        model.aiUsage.stop()
    }

    @Test(arguments: [
        ["grok", "codex", "copilot"],
        ["claude", "gemini", "perplexity"],
        ["claude", "gemini", "perplexity", "grok", "codex", "copilot", "future-provider"],
    ])
    func nativeProviderPickerKeepsIconsAndMapsRapidSelections(providers: [String]) throws {
        let originalLogoSize = LogoCache.shared.image(named: "site-openai", template: true)?.size
        var selected = try #require(providers.first)
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let host = NSHostingView(rootView: MagpieProviderPicker(providers: providers, selection: binding)
            .padding(10).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        var views: [NSView] = [host]
        var control: NSSegmentedControl?
        while let view = views.popLast() {
            if let segmented = view as? NSSegmentedControl { control = segmented; break }
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
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
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

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func manyQuotaProvidersRenderAtPopoverWidth(direction: LayoutDirection) throws {
        let providers = ["claude", "gemini", "perplexity", "grok", "codex", "copilot",
                         "unknown-provider-with-a-long-name"]
        var records: [[String: Any]] = providers.map {
            ["provider": $0, "name": "Demo account", "kind": "subscription",
             "windows": [["name": "7 days", "used": 28, "remaining": 72]]]
        }
        records[0]["user"] = "long.demo.account.for.layout@example.invalid"
        records[0]["plan"] = "self_serve_business_prolite"
        records[0]["until"] = "2099-11-01T00:00:00Z"
        records[0]["resets"] = ["count": 2, "until": "2099-10-20T12:00:00Z",
                                "each": [["until": "2099-10-20T12:00:00Z"], ["until": "2099-11-20T12:00:00Z"]]]
        records.append(["provider": "claude", "name": "Second demo account", "kind": "subscription",
                        "user": "second.demo@example.invalid", "resets": ["count": 0], "windows": []])
        let accounts = try MagpieClient.decodeQuotas(JSONSerialization.data(withJSONObject: ["object": "list", "data": records]))
        let model = AppModel(settings: settings(), historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        let host = NSHostingView(rootView: Card { MagpieQuotaAccounts(accounts: accounts) }
            .environment(model).environment(\.layoutDirection, direction)
            .environment(\.isSnapshot, true)
            .padding(16).frame(width: 380))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); model.aiUsage.stop() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 380)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["XSTATS_MAGPIE_PREVIEW_DIR"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            let filename = direction == .leftToRight ? "magpie-many-providers-ltr.png" : "magpie-many-providers-rtl.png"
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
        }
    }

    @Test func revisitingFreshPeriodDoesNotRepeatRequests() async {
        let controller = AIUsageController(settings: settings(), providers: [], magpieClient: MagpieStub())
        await controller.selectMagpiePeriod(.weekly)
        let attempt = controller.lastAttemptAt
        await controller.selectMagpiePeriod(.weekly)
        #expect(controller.lastAttemptAt == attempt)
    }

    @Test func yesterdayIsNotRepublishedAsTodaysTokens() async {
        let clock = MagpieTestClock()
        let controller = AIUsageController(settings: settings(), providers: [], magpieClient: MagpieStub(), now: clock.read)
        await controller.refresh()
        #expect(controller.todayTokens == 120)
        clock.nextDay()
        #expect(controller.todayTokens == nil)
        #expect(controller.magpieSummary(for: .daily) == nil)
    }

}
