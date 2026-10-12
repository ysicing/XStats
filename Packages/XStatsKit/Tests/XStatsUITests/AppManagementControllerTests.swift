// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Darwin
import Testing
@testable import Cleaner
@testable import XStatsUI

@Suite(.serialized)
@MainActor struct AppManagementControllerTests {
    private func app(_ name: String) -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleIdentifier: "test.\(name)", version: "1", teamIdentifier: nil)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func closedAndDisabledPagesNeverReadAndReopeningUsesCompletedSizes() async throws {
        let calls = AppManagementTestValue((list: 0, sizes: 0))
        let fixture = app("Editor")
        let controller = AppManagementController(listApps: {
            calls.withLock { $0.list += 1 }; return [fixture]
        }, inspectApp: { _ in ApplicationMetadata() }, measureSize: { _ in
            calls.withLock { $0.sizes += 1 }; return 42
        }, brewAvailable: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.withLock { $0.list } == 0)
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor { controller.sizes[fixture.id] == 42 }
        controller.setVisible(false)
        controller.setVisible(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.withLock { $0.list == 1 && $0.sizes == 1 })
        controller.setEnabled(false)
        controller.setVisible(true)
        #expect(!controller.visible && controller.apps.isEmpty)
    }

    @Test func cancellingSizeTraversalRejectsLateResults() async throws {
        let entered = AppManagementTestValue(false)
        let finished = AppManagementTestValue(false)
        let fixture = app("Slow")
        let controller = AppManagementController(listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata() }, measureSize: { _ in
            entered.withLock { $0 = true }
            defer { finished.withLock { $0 = true } }
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            return 99
        }, brewAvailable: false)
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor { entered.withLock { $0 } }
        controller.setVisible(false)
        try await waitFor { finished.withLock { $0 } }
        #expect(controller.sizes[fixture.id] == nil)
        #expect(!controller.isLoadingApps)
    }

    @Test func slowSizeTraversalDoesNotDelayOtherApplicationMetadata() async throws {
        let fixtures = [app("Large"), app("Small")]
        let entered = AppManagementTestValue(false)
        let release = AppManagementTestValue(false)
        let controller = AppManagementController(listApps: { fixtures }, inspectApp: { _ in
            ApplicationMetadata(architecture: .appleSilicon)
        }, measureSize: { _ in
            entered.withLock { $0 = true }
            while !release.withLock({ $0 }), !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            return 42
        }, brewAvailable: false)
        defer { release.withLock { $0 = true }; controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor { entered.withLock { $0 } }
        #expect(controller.apps == fixtures)
        #expect(fixtures.allSatisfy { controller.metadata[$0.id]?.architecture == .appleSilicon })
        #expect(!controller.isLoadingApps)
    }

    @Test func refreshingKeepsMeasuredSizesUntilTheirReplacementsArrive() async throws {
        let fixture = app("Editor")
        let calls = AppManagementTestValue(0)
        let entered = AppManagementTestValue(false)
        let release = AppManagementTestValue(false)
        let controller = AppManagementController(listApps: { [fixture] }, inspectApp: { _ in
            ApplicationMetadata(architecture: .appleSilicon)
        }, measureSize: { _ in
            let attempt = calls.withLock { $0 += 1; return $0 }
            if attempt == 1 { return 42 }
            entered.withLock { $0 = true }
            while !release.withLock({ $0 }), !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            return 99
        }, brewAvailable: false)
        defer { release.withLock { $0 = true }; controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor { !controller.isReading && controller.sizes[fixture.id] == 42 }
        controller.refresh()
        try await waitFor { entered.withLock { $0 } }
        #expect(controller.apps == [fixture])
        #expect(controller.sizes[fixture.id] == 42)
        release.withLock { $0 = true }
        try await waitFor { !controller.isReading }
        #expect(controller.sizes[fixture.id] == 99)
    }

    @Test func failedRefreshDoesNotLeaveAnOldSizeAsACurrentMeasurement() async throws {
        let fixture = app("Editor")
        let calls = AppManagementTestValue(0)
        let controller = AppManagementController(listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata() }, measureSize: { _ in
            let attempt = calls.withLock { $0 += 1; return $0 }
            if attempt == 1 { return 42 }
            throw CocoaError(.fileReadNoPermission)
        }, brewAvailable: false)
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor { !controller.isReading && controller.sizes[fixture.id] == 42 }
        controller.refresh()
        try await waitFor { !controller.isReading }
        #expect(controller.apps == [fixture])
        #expect(controller.sizes[fixture.id] == nil)
        #expect(controller.error == nil && !controller.isMeasuringApps)
    }

    @Test func closingDuringMetadataReadRejectsResultsAndNeverStartsMeasuring() async throws {
        let fixture = app("Editor")
        let entered = AppManagementTestValue(false)
        let finished = AppManagementTestValue(false)
        let measured = AppManagementTestValue(0)
        let controller = AppManagementController(listApps: { [fixture] }, inspectApp: { _ in
            entered.withLock { $0 = true }
            defer { finished.withLock { $0 = true } }
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            return ApplicationMetadata(architecture: .appleSilicon)
        }, measureSize: { _ in measured.withLock { $0 += 1 }; return 42 }, brewAvailable: false)
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor { entered.withLock { $0 } }
        controller.setVisible(false)
        try await waitFor { finished.withLock { $0 } }
        #expect(controller.metadata.isEmpty && controller.sizes.isEmpty)
        #expect(measured.withLock { $0 } == 0)
        #expect(!controller.isLoadingApps && !controller.isMeasuringApps)
    }

    @Test func partialSizesDoNotDiscardOtherPackagesOrTriggerRepeatedWork() async throws {
        let fixture = app("Unreadable")
        let attempts = AppManagementTestValue(0)
        let controller = AppManagementController(listApps: { [fixture] }, inspectApp: { _ in ApplicationMetadata(architecture: .intel) }, measureSize: { _ in
            attempts.withLock { $0 += 1 }; throw CocoaError(.fileReadNoPermission)
        }, brewAvailable: false)
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor { attempts.withLock { $0 } == 1 && !controller.isReading }
        controller.setVisible(false); controller.setVisible(true)
        #expect(controller.apps == [fixture] && controller.metadata[fixture.id]?.architecture == .intel)
        #expect(controller.error == nil && controller.sizes.isEmpty)
        #expect(attempts.withLock { $0 } == 1)
        controller.setVisible(false)
    }

    @Test func confirmedBrewOperationFinishesAfterPageClosesAndCannotDuplicate() async throws {
        let started = AppManagementTestValue(0)
        let release = AppManagementTestValue(false)
        let package = HomebrewPackage(name: "tool", displayName: "tool", kind: .formula, installedVersions: ["1"], latestVersion: "2",
            outdated: true, pinned: false, installationURLs: [], applicationURLs: [])
        let controller = AppManagementController(listApps: { [] }, brewAvailable: true, listPackages: { [package] }, performAction: { _, _ in
            started.withLock { $0 += 1 }
            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        })
        defer { release.withLock { $0 = true }; controller.setVisible(false) }
        controller.setVisible(true, tab: .homebrew)
        try await waitFor { !controller.packages.isEmpty && !controller.isLoadingBrew }
        controller.perform(.upgrade, package: package)
        controller.perform(.uninstall, package: package)
        controller.setVisible(false)
        try await waitFor { started.withLock { $0 } == 1 }
        #expect(controller.operation == .upgrade)
        release.withLock { $0 = true }
        try await waitFor { controller.operation == nil }
        #expect(controller.message != nil)
    }

    @Test func selfPinnedAndStalePackagesCannotStartAnUpdate() async throws {
        let writes = AppManagementTestValue(0)
        let current = HomebrewPackage(name: "current", displayName: "current", kind: .cask, installedVersions: ["1"], latestVersion: "2",
            outdated: true, pinned: false, installationURLs: [Bundle.main.bundleURL], applicationURLs: [Bundle.main.bundleURL])
        let pinned = HomebrewPackage(name: "pinned", displayName: "pinned", kind: .formula, installedVersions: ["1"], latestVersion: "2",
            outdated: true, pinned: true, installationURLs: [], applicationURLs: [])
        let stale = HomebrewPackage(name: "removed", displayName: "removed", kind: .formula, installedVersions: ["1"], latestVersion: "2",
            outdated: true, pinned: false, installationURLs: [], applicationURLs: [])
        let controller = AppManagementController(listApps: { [] }, brewAvailable: true,
            listPackages: { [current, pinned] }, performAction: { _, _ in writes.withLock { $0 += 1 } })
        defer { controller.setVisible(false) }
        controller.setVisible(true, tab: .homebrew)
        try await waitFor { !controller.isLoadingBrew && controller.packages.count == 2 }
        controller.perform(.uninstall, package: current)
        controller.perform(.upgrade, package: pinned)
        controller.perform(.upgrade, package: stale)
        #expect(controller.operation == nil && writes.withLock { $0 } == 0)
    }

    /// 可选实机检查：只读真实清单，关闭页面后等待目录遍历退出，确认不再发起后台读取。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_APP_MANAGEMENT_RESOURCE_REPORT"] != nil))
    func nativeInventoryStopsWhenClosed() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["XSTATS_APP_MANAGEMENT_RESOURCE_REPORT"])
        let calls = AppManagementTestValue((apps: 0, brew: 0, sizes: 0, active: 0))
        let controller = AppManagementController(listApps: {
            calls.withLock { $0.apps += 1 }
            return try AppUninstaller.scanInstalledApps()
        }, measureSize: { url in
            calls.withLock { $0.sizes += 1; $0.active += 1 }
            defer { calls.withLock { $0.active -= 1 } }
            return try CleanEngine.scanAllocatedSize(of: url)
        }, listPackages: {
            calls.withLock { $0.brew += 1 }
            return try await HomebrewManagement.inventory()
        })
        defer { controller.setVisible(false) }
        controller.setVisible(true)
        try await waitFor { !controller.apps.isEmpty && controller.hasBrewInventory }
        let appCount = controller.apps.count
        let packageCount = controller.packages.count
        controller.setVisible(false)
        try await waitFor { calls.withLock { $0.active == 0 } }
        let before = calls.withLock { $0 }
        var cpuBefore = rusage()
        getrusage(RUSAGE_SELF, &cpuBefore)
        try await Task.sleep(for: .seconds(5))
        var cpuAfter = rusage()
        getrusage(RUSAGE_SELF, &cpuAfter)
        #expect(calls.withLock { $0.apps == before.apps && $0.brew == before.brew && $0.sizes == before.sizes && $0.active == 0 })
        let cpu = Double(cpuAfter.ru_utime.tv_sec + cpuAfter.ru_stime.tv_sec - cpuBefore.ru_utime.tv_sec - cpuBefore.ru_stime.tv_sec)
            + Double(cpuAfter.ru_utime.tv_usec + cpuAfter.ru_stime.tv_usec - cpuBefore.ru_utime.tv_usec - cpuBefore.ru_stime.tv_usec) / 1_000_000
        try "apps=\(appCount) packages=\(packageCount) closed_new_reads=0 closed_cpu_seconds=\(cpu) observed_seconds=5\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// 测试回调跨线程共享的计数和信号，只允许在锁内访问。
private final class AppManagementTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ work: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return work(&value)
    }
}
