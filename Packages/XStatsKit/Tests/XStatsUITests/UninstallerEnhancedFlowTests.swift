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
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("UninstallRetry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Caches")
        let cache = AppLeftover(url: root.appendingPathComponent("test.retry.\(UUID())"), kind: .caches, size: 100)
        let shared = AppLeftover(url: root.appendingPathComponent("test.shared.\(UUID())"), kind: .caches, size: 200, requiresReview: true)
        for item in [cache, shared] { try FileManager.default.createDirectory(at: item.url, withIntermediateDirectories: true) }
        var batches: [[URL]] = []
        var completion: (@Sendable ([URL: URL], String?) -> Void)?
        let controller = UninstallerController(currentBundleIdentifier: nil, home: home.path, findLeftovers: { _ in [body, cache, shared] },
            checkInstallations: { _ in AppInstallationCheck() },
            recycleFiles: { urls, reply in batches.append(urls); completion = reply })
        defer { controller.setEnabled(false) }
        controller.select(app)
        // 完整测试并发运行时，主执行器可能被其他用例占用超过 30 秒。
        // 沿用卸载测试的有界等待预算；此处验证扫描结果，不衡量扫描耗时。
        let deadline = ContinuousClock.now + .seconds(120)
        while controller.isScanning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.canUninstall)
        #expect(controller.chosen == [body.id, cache.id])
        #expect(controller.chosenSize == 1100)
        controller.requestUninstall(); await controller.confirmUninstall()?.value
        try #require(controller.isRemoving)
        #expect(batches == [[body.url, cache.url]])
        completion?([body.url: URL(fileURLWithPath: "/tmp/trash-fixture")], "permission denied")
        while controller.isRemoving, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!controller.isRemoving && controller.canUninstall)
        #expect(controller.selected == app && controller.leftovers == [cache, shared])
        #expect(!controller.includesApplication && controller.chosen == [cache.id])
        controller.requestUninstall(); controller.cancelUninstall(); await controller.confirmUninstall()?.value
        #expect(batches.count == 1)
        controller.requestUninstall(); await controller.confirmUninstall()?.value
        #expect(batches.last == [cache.url])
        completion?([cache.url: URL(fileURLWithPath: "/tmp/trash-cache")], nil)
        while controller.isRemoving, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.leftovers == [shared] && !controller.canUninstall)
        controller.toggle(shared)
        #expect(controller.canUninstall && controller.chosen == [shared.id])
        controller.requestUninstall(); await controller.confirmUninstall()?.value
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
            checkInstallations: { _ in AppInstallationCheck() },
            recycleFiles: { _, _ in Issue.record("Unsafe residual path reached recycling") })
        defer { controller.setEnabled(false) }
        controller.select(app)
        // 完整测试并发运行时，主执行器可能被其他用例占用超过 30 秒。
        // 沿用卸载测试的有界等待预算；此处验证扫描结果，不衡量扫描耗时。
        let deadline = ContinuousClock.now + .seconds(120)
        while controller.isScanning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.canUninstall)
        controller.requestUninstall(); await controller.confirmUninstall()?.value
        #expect(!controller.isRemoving && controller.outcome?.isError == true)
        #expect(controller.selected == app && controller.leftovers == [body, outside])
    }
    @Test(arguments: [false, true])
    func copiesOrUncertainInstallationsAtConfirmationKeepResidualData(_ uncertain: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("UninstallCopies-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Fixture-\(UUID()).app"), name: "Fixture",
                               bundleIdentifier: "com.example.fixture", version: nil, teamIdentifier: nil)
        let body = AppLeftover(url: app.url, kind: .application, size: 100)
        let data = AppLeftover(url: home.appendingPathComponent("Library/Caches/com.example.fixture"), kind: .caches, size: 200)
        try FileManager.default.createDirectory(at: data.url, withIntermediateDirectories: true)
        var batches: [[URL]] = []
        let controller = UninstallerController(currentBundleIdentifier: nil, home: home.path,
            findLeftovers: { _ in [body, data] },
            checkInstallations: { _ in
                uncertain ? AppInstallationCheck(unreadableDirectories: [home.appendingPathComponent("Applications")])
                    : AppInstallationCheck(otherInstalledCopies: [home.appendingPathComponent("Applications/Other.app")])
            }, recycleFiles: { urls, reply in batches.append(urls); reply([:], nil) })
        defer { controller.setEnabled(false) }
        await controller.select(app)?.value
        #expect(controller.chosen.count == 2)
        controller.requestUninstall()
        await controller.confirmUninstall()?.value
        #expect(batches == [[body.url]])
        #expect(controller.installationCheckIncomplete == uncertain)
        #expect(controller.otherInstalledCopies.isEmpty == uncertain)
        #expect(controller.leftovers.allSatisfy { $0.kind == .application })
        #expect(FileManager.default.fileExists(atPath: data.url.path))
    }

    @Test func residualOnlyRetryWithNewCopyReportsPreservedDataInsteadOfSilentlyReturning() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("UninstallResidualCopy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Fixture-\(UUID()).app"), name: "Fixture",
                               bundleIdentifier: "com.example.fixture", version: nil, teamIdentifier: nil)
        let data = AppLeftover(url: home.appendingPathComponent("Library/Caches/com.example.fixture"), kind: .caches, size: 200)
        let controller = UninstallerController(currentBundleIdentifier: nil, home: home.path,
            findLeftovers: { _ in [data] },
            checkInstallations: { _ in AppInstallationCheck(otherInstalledCopies: [home.appendingPathComponent("Applications/Other.app")]) },
            recycleFiles: { _, _ in Issue.record("Residual data shared with another copy must not be recycled") })
        defer { controller.setEnabled(false) }
        // 本体已移到废纸篓，只剩残留重试；确认时才发现另一个副本。
        controller.showPreview(app: app, items: [data], applicationRemoved: true)
        try #require(controller.canUninstall)
        controller.requestUninstall()
        await controller.confirmUninstall()?.value
        #expect(!controller.isRemoving)
        #expect(controller.outcome?.isError == true, "清空选择后必须给出保留数据的结果，而不是无反馈返回")
        #expect(controller.otherInstalledCopies.count == 1)
    }

    @Test func disablingBeforePreflightCompletesCancelsRecyclingAndReleasesSelection() async throws {
        let app = InstalledApp(url: URL(fileURLWithPath: "/Applications/Fixture-\(UUID()).app"), name: "Fixture",
                               bundleIdentifier: "com.example.fixture", version: nil, teamIdentifier: nil)
        let body = AppLeftover(url: app.url, kind: .application, size: 100)
        let controller = UninstallerController(currentBundleIdentifier: nil, findLeftovers: { _ in [body] },
            checkInstallations: { _ in try Task.checkCancellation(); return AppInstallationCheck() },
            recycleFiles: { _, _ in Issue.record("Disabled preflight must not submit recycling") })
        await controller.select(app)?.value
        controller.requestUninstall()
        let task = controller.confirmUninstall()
        controller.setEnabled(false)
        await task?.value
        #expect(!controller.isRemoving && controller.selected == nil && controller.leftovers.isEmpty)
    }

}
