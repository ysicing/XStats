// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Metrics
import Testing
@testable import Cleaner
@testable import XStatsUI

@MainActor
struct UninstallerSafetyTests {
    private func target(_ name: String = UUID().uuidString, identifier: String = "test.uninstall.target") -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/Audit-\(name).app"), name: name,
                     bundleIdentifier: identifier, version: nil, teamIdentifier: nil)
    }

    @Test(arguments: [false, true])
    func currentApplicationAndItsCopiesAreRejectedByEveryEntry(uppercase: Bool) {
        let own = "test.uninstall.current"
        let app = target(identifier: uppercase ? own.uppercased() : own)
        #expect(throws: AppUninstallError.currentApp) {
            try AppUninstaller.validate(app, currentBundleIdentifier: own)
        }
        let controller = UninstallerController(currentBundleIdentifier: own)
        controller.select(app)
        #expect(controller.selected == nil && !controller.isScanning)
        controller.quit(app)
        #expect(controller.outcome?.isError == true)
        #expect(controller.outcome?.text == AppUninstallError.currentApp.description)
        #expect(controller.pendingUninstall == nil)
    }

    @Test func movingOnlyResidueKeepsTheApplicationAndReportsActualBytes() async throws {
        let app = target()
        let body = AppLeftover(url: app.url, kind: .application, size: 1_000_000)
        let cache = AppLeftover(url: URL(fileURLWithPath: "/tmp/audit-cache"), kind: .caches, size: 1_000)
        let controller = UninstallerController(currentBundleIdentifier: "test.uninstall.current", findLeftovers: { _ in [body, cache] })
        controller.select(app)
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.isScanning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.canUninstall)
        controller.finishUninstall(app, items: [body, cache],
                                   moved: [cache.url: URL(fileURLWithPath: "/tmp/trash-cache")], errorMessage: "permission denied")
        #expect(controller.selected == app)
        #expect(controller.leftovers == [body])
        #expect(controller.chosen == [body.id] && controller.canUninstall)
        #expect(controller.outcome?.isError == true)
        #expect(controller.outcome?.text.contains("应用本体未能移动") == true)
        #expect(controller.outcome?.text.contains(Format.bytes(cache.size, base: .decimal)) == true)
        #expect(controller.outcome?.text.contains(Format.bytes(body.size + cache.size, base: .decimal)) == false)
        #expect(controller.outcome?.text.contains("permission denied") == true)
        #expect(!controller.isRemoving)
    }

    @Test func failedRecycleKeepsSelectionAndSuccessfulBodyClearsIt() async throws {
        let app = target()
        let body = AppLeftover(url: app.url, kind: .application, size: 1000)
        let controller = UninstallerController(currentBundleIdentifier: "test.uninstall.current", findLeftovers: { _ in [body] })
        controller.select(app)
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.isScanning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.canUninstall)
        controller.finishUninstall(app, items: [body], moved: [:], errorMessage: "denied")
        #expect(controller.selected == app && controller.outcome?.isError == true)
        controller.finishUninstall(app, items: [body], moved: [app.url: URL(fileURLWithPath: "/tmp/trash-app")], errorMessage: nil)
        #expect(controller.selected == nil && controller.outcome?.isError == false)
    }

    @Test func removalFreezesSelectionAndBlocksNewScans() async throws {
        let app = target()
        let body = AppLeftover(url: app.url, kind: .application, size: 1000)
        let transaction = RecycleTransaction()
        let controller = UninstallerController(currentBundleIdentifier: nil,
            listApplications: { Issue.record("回收期间不能启动列表扫描"); return [] },
            findLeftovers: { _ in [body] },
            recycleFiles: { urls, completion in transaction.urls = urls; transaction.completion = completion })
        controller.select(app)
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.isScanning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.canUninstall)
        controller.requestUninstall()
        controller.confirmUninstall()
        try #require(controller.isRemoving)
        #expect(transaction.urls == [app.url])
        controller.select(target())
        controller.loadApps()
        #expect(controller.selected == app && !controller.isLoading && !controller.isScanning)
        transaction.completion?([app.url: URL(fileURLWithPath: "/tmp/trash-app")], nil)
        while controller.isRemoving, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isRemoving && controller.selected == nil)
    }
}

@MainActor
private final class RecycleTransaction {
    var urls: [URL] = []
    var completion: (@Sendable ([URL: URL], String?) -> Void)?
}
