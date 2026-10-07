// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct PublicLookupLifecycleTests {
    @Test func closingAndReenablingNetworkRejectsTheOldLookupWithoutDependingOnVisibilityDelivery() async throws {
        let domain = "PublicLookupLifecycle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        let gate = PublicLookupGate()
        let controller = NetworkController(settings: settings, cacheDefaults: defaults,
            fetchPublicAddresses: { await gate.fetch() }, fetchGeo: { _ in await gate.countGeo(); return nil })
        controller.lookUpPublicAddresses()
        try await waitForRequests(gate, count: 1)
        settings.setModuleEnabled(.network, false)
        settings.setModuleEnabled(.network, true)
        await gate.finish(0, country: "US")
        while controller.isLookingUpPublic { try Task.checkCancellation(); await Task.yield() }
        #expect(await gate.geoCalls == 0)
        #expect(controller.publicResults.isEmpty)
        #expect(defaults.data(forKey: "publicAddressCache4") == nil)
    }

    @Test func disablingLookupPreventsFollowUpRequestsAndCacheWrite() async throws {
        let domain = "PublicLookupLifecycle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.publicIPLookup = true
        let gate = PublicLookupGate()
        let controller = NetworkController(settings: settings, cacheDefaults: defaults,
            fetchPublicAddresses: { await gate.fetch() },
            fetchGeo: { _ in await gate.countGeo(); return nil })
        controller.lookUpPublicAddresses()
        try await waitForRequests(gate, count: 1)
        settings.publicIPLookup = false
        controller.clearPublicAddresses()
        await gate.finish(0, country: "US")
        try await Task.sleep(for: .milliseconds(30))
        #expect(await gate.geoCalls == 0)
        #expect(controller.publicResults.isEmpty && !controller.isLookingUpPublic)
        #expect(defaults.data(forKey: "publicAddressCache4") == nil)
    }

    @Test func obsoleteCompletionCannotOverwriteNewQueryOrItsLoadingState() async throws {
        let domain = "PublicLookupLifecycle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.publicIPLookup = true
        let gate = PublicLookupGate()
        let controller = NetworkController(settings: settings, cacheDefaults: defaults,
            fetchPublicAddresses: { await gate.fetch() }, fetchGeo: { _ in nil })
        controller.lookUpPublicAddresses()
        try await waitForRequests(gate, count: 1)
        controller.clearPublicAddresses()
        controller.lookUpPublicAddresses(force: true)
        try await waitForRequests(gate, count: 2)
        // 旧请求先回来，也不能清掉正在执行的新请求的加载状态。
        await gate.finish(0, country: "US")
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.isLookingUpPublic && controller.publicResults.isEmpty)
        await gate.finish(1, country: "JP")
        let deadline = ContinuousClock.now + .seconds(120)
        while controller.isLookingUpPublic, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.publicAddresses?.countryCode == "JP")
        #expect(controller.publicAddresses?.ipv4 == "198.51.100.2")
        let data = try #require(defaults.data(forKey: "publicAddressCache4"))
        let cache = String(decoding: data, as: UTF8.self)
        #expect(cache.contains("JP") && !cache.contains("US"))
    }

    @Test func pausingCancelsPendingLookupAndStopsNewQueries() async throws {
        let domain = "PublicLookupLifecycle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.publicIPLookup = true
        let gate = PublicLookupGate()
        let controller = NetworkController(settings: settings, cacheDefaults: defaults,
            fetchPublicAddresses: { await gate.fetch() }, fetchGeo: { _ in nil })
        controller.lookUpPublicAddresses()
        try await waitForRequests(gate, count: 1)
        controller.setPaused(true)
        controller.lookUpPublicAddresses(force: true)
        await gate.finish(0, country: "US")
        try await Task.sleep(for: .milliseconds(30))
        #expect(await gate.requests == 1)
        #expect(controller.publicResults.isEmpty && !controller.isLookingUpPublic)
        #expect(defaults.data(forKey: "publicAddressCache4") == nil)
    }

    @Test func disablingDuringGeoLookupRejectsLateGeoCompletion() async throws {
        let domain = "PublicLookupLifecycle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.publicIPLookup = true
        let gate = GeoLookupGate()
        let controller = NetworkController(settings: settings, cacheDefaults: defaults,
            fetchPublicAddresses: { PublicAddresses(ipv4: "198.51.100.9", countryCode: "US") },
            fetchGeo: { _ in await gate.lookup() })
        defer { controller.clearPublicAddresses(); Task { await gate.finish() } }
        controller.lookUpPublicAddresses(force: true)
        let deadline = ContinuousClock.now + .seconds(120)
        while !(await gate.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await gate.started)
        settings.publicIPLookup = false
        controller.clearPublicAddresses()
        await gate.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.publicResults.isEmpty && !controller.isLookingUpPublic)
        #expect(defaults.data(forKey: "publicAddressCache4") == nil)
    }

    private func waitForRequests(_ gate: PublicLookupGate, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while await gate.requests < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await gate.requests == count)
    }
}

private actor GeoLookupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func lookup() async -> PublicAddressLookup.GeoInfo? {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return nil
    }
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

/// 故意不响应取消的服务替身，验证即使迟到回调到达，也不能发布过期状态。
private actor PublicLookupGate {
    private var continuations: [Int: CheckedContinuation<PublicAddresses, Never>] = [:]
    private(set) var requests = 0
    private(set) var geoCalls = 0
    func fetch() async -> PublicAddresses {
        let index = requests
        requests += 1
        return await withCheckedContinuation { continuations[index] = $0 }
    }
    func finish(_ index: Int, country: String) {
        continuations.removeValue(forKey: index)?.resume(returning:
            PublicAddresses(ipv4: "198.51.100.\(index + 1)", countryCode: country))
    }
    func countGeo() { geoCalls += 1 }
}
