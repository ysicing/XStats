// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct UninstallerEnhancedFlowTests {
    @Test func uncertainCandidatesStartUnselectedAndRetryKeepsOnlyRemainingItems() async throws {
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Uninstall-\(UUID()).app"), name: "Fixture",
                               bundleIdentifier: "test.uninstall.fixture", version: nil, teamIdentifier: nil)
        let body = AppLeftover(url: app.url, kind: .application, size: 1000)
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let cache = AppLeftover(url: root.appendingPathComponent("test.retry.\(UUID())"), kind: .caches, size: 100)
        let shared = AppLeftover(url: root.appendingPathComponent("test.shared.\(UUID())"), kind: .caches, size: 200, requiresReview: true)
        var batches: [[URL]] = []
        var completion: (@Sendable ([URL: URL], String?) -> Void)?
        let controller = UninstallerController(currentBundleIdentifier: nil, findLeftovers: { _ in [body, cache, shared] },
            recycleFiles: { urls, reply in batches.append(urls); completion = reply })
        defer { controller.setEnabled(false) }
        controller.select(app)
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.isScanning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.canUninstall)
        #expect(controller.chosen == [body.id, cache.id])
        #expect(controller.chosenSize == 1100)
        controller.requestUninstall(); controller.confirmUninstall()
        try #require(controller.isRemoving)
        #expect(batches == [[body.url, cache.url]])
        completion?([body.url: URL(fileURLWithPath: "/tmp/trash-fixture")], "permission denied")
        while controller.isRemoving, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!controller.isRemoving && controller.canUninstall)
        #expect(controller.selected == app && controller.leftovers == [cache, shared])
        #expect(!controller.includesApplication && controller.chosen == [cache.id])
        controller.requestUninstall(); controller.cancelUninstall(); controller.confirmUninstall()
        #expect(batches.count == 1)
        controller.requestUninstall(); controller.confirmUninstall()
        #expect(batches.last == [cache.url])
        completion?([cache.url: URL(fileURLWithPath: "/tmp/trash-cache")], nil)
        while controller.isRemoving, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.leftovers == [shared] && !controller.canUninstall)
        controller.toggle(shared)
        #expect(controller.canUninstall && controller.chosen == [shared.id])
        controller.requestUninstall(); controller.confirmUninstall()
        #expect(batches.last == [shared.url])
        completion?([shared.url: URL(fileURLWithPath: "/tmp/trash-shared")], nil)
        while controller.isRemoving, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.selected == nil && controller.outcome?.isError == false)
    }

    @Test func outsideResidualPathNeverReachesRecycler() async throws {
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Uninstall-\(UUID()).app"), name: "Fixture",
                               bundleIdentifier: "test.uninstall.fixture", version: nil, teamIdentifier: nil)
        let body = AppLeftover(url: app.url, kind: .application, size: 1000)
        let outside = AppLeftover(url: URL(fileURLWithPath: "/tmp/outside-residue"), kind: .caches, size: 100)
        let controller = UninstallerController(currentBundleIdentifier: nil, findLeftovers: { _ in [body, outside] },
            recycleFiles: { _, _ in Issue.record("Unsafe residual path reached recycling") })
        defer { controller.setEnabled(false) }
        controller.select(app)
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.isScanning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.canUninstall)
        controller.requestUninstall(); controller.confirmUninstall()
        #expect(!controller.isRemoving && controller.outcome?.isError == true)
        #expect(controller.selected == app && controller.leftovers == [body, outside])
    }
}
