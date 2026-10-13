// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Darwin
import Testing
@testable import Cleaner

struct CleanupReviewTests {
    @Test func scanDoesNotEnterUnrelatedApplicationData() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let appURL = home.appendingPathComponent("Applications/Pulse.app")
        let unrelated = ["Application Support/Music", "Caches/com.apple.Safari", "Logs/OtherApp"]
            .map { home.appendingPathComponent("Library/" + $0) }
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        for directory in unrelated {
            // 即使其他 App 的目录里出现同名子项，也不能为了查找它进入该 App 的数据。
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("com.egoist.pulse"), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: home) }
        let app = InstalledApp(url: appURL, name: "Pulse", bundleIdentifier: "com.egoist.pulse", version: nil, teamIdentifier: nil)

        let report = try AppUninstaller.scanLeftoversReport(for: app, home: home.path,
            identity: AppUninstallIdentity(identifiers: [app.bundleIdentifier], names: [app.name]),
            installations: AppInstallationCheck(), userCache: nil)

        #expect(report.items.map(\.url) == [appURL])
        #expect(report.unreadablePaths.isEmpty)
    }

    @Test(.enabled(if: geteuid() != 0))
    func unreadableUninstallDirectoryIsReportedInsteadOfAnEmptyList() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let caches = home.appendingPathComponent("Library/Caches")
        let appURL = home.appendingPathComponent("Applications/Fixture.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: caches.appendingPathComponent("data"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: caches.path)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: caches.path)
        let app = InstalledApp(url: appURL, name: "Fixture", bundleIdentifier: "com.example.fixture", version: nil, teamIdentifier: nil)
        let report = try AppUninstaller.scanLeftoversReport(for: app, home: home.path)
        #expect(report.items.contains { $0.kind == .application })
        #expect(report.unreadablePaths.contains { $0.lastPathComponent == "Caches" })
        let sizeRule = CleanRule(id: "unreadable", category: .system, title: "fixture", detail: "", symbol: "trash", minimumAge: 0) { _ in [caches] }
        // 父根不可作为清理目标，测试其受限子目录的完整大小入口。
        do {
            _ = try CleanEngine.scanAllocatedSize(of: caches)
            Issue.record("Unreadable directory produced a complete size")
        } catch {}
        let scan = await CleanEngine.scan([sizeRule], environment: CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] }))
        #expect(scan.first?.skippedReasons[.protected] == 1)
    }

    @Test func exclusionsProtectChildrenParentsAndResolvedAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let excluded = root.appendingPathComponent("Cache/keep")
        try FileManager.default.createDirectory(at: excluded.deletingLastPathComponent(), withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("Cache"))
        let paths = [excluded.path]
        #expect(CleanupExclusions.overlaps(excluded, paths: paths))
        #expect(CleanupExclusions.overlaps(excluded.appendingPathComponent("file"), paths: paths))
        #expect(CleanupExclusions.overlaps(excluded.deletingLastPathComponent(), paths: paths))
        #expect(CleanupExclusions.overlaps(alias.appendingPathComponent("keep"), paths: paths))
        #expect(!CleanupExclusions.overlaps(root.appendingPathComponent("Cache/keeper"), paths: paths))
        #expect(CleanupExclusions.normalized(["relative", "/bad\npath", excluded.path, excluded.path]) == [excluded.standardizedFileURL.path])
    }

    @Test func exclusionPreventsToolExecutionAndDoesNotPublishPartialSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("Library/Caches/go-build")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data"))
        let environment = CleanEnvironment(home: root.path, runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
                                          runTool: { tool, args in
            if tool == "go", args == ["env", "-json", "GOCACHE", "GOMODCACHE"] {
                let paths = ["GOCACHE": cache.path, "GOMODCACHE": root.appendingPathComponent("go/pkg/mod").path]
                return ToolRunResult(status: 0, output: String(decoding: try JSONEncoder().encode(paths), as: UTF8.self))
            }
            Issue.record("Excluded tool was executed"); throw CancellationError()
        })
        let rule = try #require(RuleCatalog.rules().first { $0.id == "developer.go" })
        let scans = await CleanEngine.scan([rule], environment: environment)
        try #require(scans.first?.isCleanable == true)
        let partial = RuleScan(rule: rule, items: scans[0].items, skippedCount: 0, blocked: nil, unreadableCount: 1)
        let partialReport = await CleanEngine.clean([partial], selected: [rule.id], preferTrash: false, environment: environment, log: nil)
        #expect(!partial.isCleanable && partialReport.removedCount == 0)
        var excluded = environment
        excluded.excludedPaths = [cache.appendingPathComponent("data").path]
        let filtered = await CleanEngine.scan([rule], environment: excluded)
        #expect(filtered.first?.blocked == .excluded)
        let result = await CleanEngine.clean(scans, selected: [rule.id], preferTrash: false, environment: excluded, log: nil)
        #expect(result.removedCount == 0 && FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func cleanerRefreshesRunningApplicationsInsteadOfTrustingScanSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("Library/Caches/com.example.busy")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data"))
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: cache.path)
        let environment = CleanEnvironment(home: root.path, runningBundleIdentifiers: { [] })
        let scans = await CleanEngine.scan([RuleCatalog.userCaches], environment: environment)
        try #require(scans.first?.items.count == 1)
        let report = await CleanEngine.clean(scans, selected: [RuleCatalog.userCaches.id], preferTrash: false,
                                            environment: environment, log: nil, refreshRunningApps: { ["com.example.busy"] })
        #expect(report.removedCount == 0 && report.skippedCount == 1)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("data").path))
    }

    @Test func readFailuresRemainDistinctFromEmptyAndProtectedItems() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = CleanEnvironment(home: root.path, runningBundleIdentifiers: { [] })
        let rule = CleanRule(id: "fixture", category: .system, title: "fixture", detail: "", symbol: "trash") {
            [$0.home + "/Library/Caches/missing"].map { URL(fileURLWithPath: $0) }
        }
        let scans = await CleanEngine.scan([rule], environment: environment)
        #expect(scans.first?.unreadableCount == 1 && scans.first?.items.isEmpty == true)
        let failed = CleanRule(id: "error", category: .system, title: "fixture", detail: "", symbol: "trash") { _ in
            throw CocoaError(.fileReadUnknown)
        }
        let permission = CleanRule(id: "permission", category: .system, title: "fixture", detail: "", symbol: "trash") { _ in
            throw CleanerAccessError.permissionDenied
        }
        let failures = await CleanEngine.scan([failed, permission], environment: environment)
        #expect(failures[0].blocked != .needsFullDiskAccess)
        #expect(failures[1].blocked == .needsFullDiskAccess)
    }

    @Test func genericCachesDoNotOfferToolManagedGoOrYarnDirectories() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["go-build", "Yarn", "com.example.idle"] {
            let url = home.appendingPathComponent("Library/Caches/\(name)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: url.appendingPathComponent("data"))
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: url.path)
        }
        let results = await CleanEngine.scan([RuleCatalog.userCaches], environment: CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] }))
        #expect(results.first?.items.map(\.url.lastPathComponent) == ["com.example.idle"])
    }
}

struct CleanupReviewRegressionTests {
    @Test(.enabled(if: geteuid() != 0))
    func unrelatedUnreadableDirectoryDoesNotDiscardVerifiedAppAndCache() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let appURL = home.appendingPathComponent("Applications/Fixture.app")
        let cache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let unrelated = home.appendingPathComponent("Library/Application Support/OtherVendor")
        for url in [appURL, cache, unrelated] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data"))
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unrelated.path)
            try? fm.removeItem(at: home)
        }
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unrelated.path)
        let app = InstalledApp(url: appURL, name: "Fixture", bundleIdentifier: "com.example.fixture", version: nil, teamIdentifier: nil)
        let found = try AppUninstaller.scanLeftovers(for: app, home: home.path)
        #expect(found.contains { $0.kind == .application })
        #expect(found.contains { $0.kind == .caches && $0.url.lastPathComponent == cache.lastPathComponent })
        let report = try AppUninstaller.scanLeftoversReport(for: app, home: home.path)
        #expect(!report.unreadablePaths.contains { $0.lastPathComponent == unrelated.lastPathComponent })
    }

    @Test func customNpmCacheExclusionPreventsGlobalCleanup() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let oldCache = home.appendingPathComponent(".npm/_cacache")
        let actualCache = home.appendingPathComponent("CustomCache")
        for url in [oldCache, actualCache.appendingPathComponent("_cacache")] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: url.appendingPathComponent("data"))
        }
        let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
            runTool: { _, args in
                if args == ["config", "get", "cache"] { return ToolRunResult(status: 0, output: actualCache.path) }
                Issue.record("Cleanup was invoked for a protected custom cache")
                return ToolRunResult(status: 0, output: "")
            }, excludedPaths: [actualCache.path])
        let rule = try #require(RuleCatalog.rules().first { $0.id == "developer.npm" })
        let scans = await CleanEngine.scan([rule], environment: environment)
        #expect(scans.first?.blocked == .excluded)
        _ = await CleanEngine.clean(scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    }
}
