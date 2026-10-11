// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// Adapted from gentpan/OpenStats ee0b5e4; see ThirdPartyNotices.md.

import Foundation
import Testing
@testable import Cleaner

@Suite struct AppUninstallerMoleTests {
    private struct Fixture {
        let root: URL
        let home: URL

        init() throws {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-mole-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            root = temporary.resolvingSymlinksInPath()
            home = root.appendingPathComponent("Home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func app(name: String = "OpenCode", identifier: String = "ai.opencode.desktop") throws -> InstalledApp {
            let url = try directory("Applications/\(name).app/Contents").deletingLastPathComponent()
            let metadata = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundleDisplayName": name,
                            "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            return InstalledApp(url: url, name: name, bundleIdentifier: identifier, version: "1", teamIdentifier: nil)
        }

        func embeddedHelper(in app: InstalledApp, identifier: String) throws {
            let contents = app.url.appendingPathComponent("Contents/XPCServices/FixtureHelper.xpc/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
                "CFBundleName": "Fixture Helper", "CFBundlePackageType": "XPC!"], format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }

        @discardableResult
        func directory(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @discardableResult
        func file(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            return url
        }

        func scan(_ app: InstalledApp, installed: [InstalledApp] = [], userCache: URL? = nil,
                  unreadableInstallations: [URL] = []) throws -> AppLeftoverScan {
            let copies = installed.filter {
                $0.bundleIdentifier.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame && $0.url != app.url
            }.map(\.url)
            return try AppUninstaller.scanLeftoversReport(for: app, home: home.path, identity: AppUninstallIdentity(app: app),
                installations: AppInstallationCheck(otherInstalledCopies: copies, unreadableDirectories: unreadableInstallations),
                userCache: userCache)
        }
    }

    @Test func openCodeConfigurationIsSpecificToItsDesktopIdentifierAndRequiresReview() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let config = try fixture.directory(".config/opencode")
        let cache = try fixture.directory(".cache/opencode")
        let preserved = try fixture.file(".config/opencode-other/settings.json")
        let result = try fixture.scan(app)

        #expect(Set(result.items.map { $0.url.path }) == [app.url.path, config.path, cache.path])
        for target in [config, cache] {
            #expect(result.items.first { $0.url.path == target.path }?.requiresReview == true)
            #expect(throws: Never.self) { try AppUninstaller.validateLeftover(target, for: app, home: fixture.home.path, userCache: nil) }
        }
        let other = try fixture.app(name: "OpenCode Lookalike", identifier: "ai.opencode.desktop.other")
        #expect(try fixture.scan(other).items.map { $0.url.path } == [other.url.path])
        for parent in [".config", ".cache"] {
            #expect(throws: AppUninstallError.self) {
                try AppUninstaller.validateLeftover(fixture.home.appendingPathComponent(parent), for: app, home: fixture.home.path, userCache: nil)
            }
        }
        #expect(FileManager.default.fileExists(atPath: preserved.path))
    }

    @Test func nameOnlyCachesPreferencesAndSavedStateRequireReviewWithExactNames() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let targets = [try fixture.directory("Library/Caches/opencode"),
                       try fixture.file("Library/Preferences/OpenCode.plist"),
                       try fixture.directory("Library/Saved Application State/OpenCode.savedState")]
        let neighbors = [try fixture.directory("Library/Caches/OpenCodePlus"),
                         try fixture.file("Library/Preferences/OpenCodePlus.plist"),
                         try fixture.file("Library/Preferences/OpenCode.json"),
                         try fixture.directory("Library/Saved Application State/OpenCodePlus.savedState")]
        let result = try fixture.scan(app)

        #expect(Set(result.items.map { $0.url.path }) == Set([app.url.path] + targets.map(\.path)))
        for target in targets { #expect(result.items.first { $0.url.path == target.path }?.requiresReview == true) }
        for neighbor in neighbors { #expect(!result.items.contains { $0.url.path == neighbor.path }) }
    }

    @Test func crashReportsUseNameBoundariesAndRecognizedReportExtensions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let targets = [
            try fixture.file("Library/Application Support/CrashReporter/OpenCode_ABC.plist"),
            try fixture.file("Library/Logs/DiagnosticReports/OpenCode-2026-10-10.ips"),
            try fixture.file("Library/Logs/DiagnosticReports/OpenCode_2026-10-10.crash"),
            try fixture.file("Library/Logs/DiagnosticReports/OpenCode.spin"),
            try fixture.file("Library/Logs/DiagnosticReports/OpenCode.diag"),
        ]
        for path in ["Library/Application Support/CrashReporter/OpenCodePlus_ABC.plist",
                     "Library/Application Support/CrashReporter/OpenCode_ABC.json",
                     "Library/Logs/DiagnosticReports/OpenCodePlus-2026.ips",
                     "Library/Logs/DiagnosticReports/OpenCode-2026.txt",
                     "Library/Logs/DiagnosticReports/OpenCode-2026.plist"] { try fixture.file(path) }
        let result = try fixture.scan(app)

        #expect(Set(result.items.map { $0.url.path }) == Set([app.url.path] + targets.map(\.path)))
        for target in targets {
            #expect(result.items.first { $0.url.path == target.path }?.kind == .logs)
            #expect(result.items.first { $0.url.path == target.path }?.requiresReview == true)
        }
    }

    @Test func webContentAndURLSessionDownloadsSelectOwnedChildrenAndKeepSharedRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let roots = ["Library/WebKit/com.apple.WebKit.WebContent", "Library/Caches/com.apple.nsurlsessiond/Downloads"]
        var targets: [URL] = []
        for root in roots {
            targets.append(try fixture.directory(root + "/ai.opencode.desktop"))
            try fixture.directory(root + "/ai.opencode.desktop-other")
            try fixture.directory(root + "/ai.opencode.desktopplus")
            try fixture.directory(root + "/com.other.app")
        }
        let result = try fixture.scan(app)

        #expect(Set(result.items.map { $0.url.path }) == Set([app.url.path] + targets.map(\.path)))
        for target in targets { #expect(result.items.first { $0.url.path == target.path }?.requiresReview == false) }
        for root in roots + ["Library/Caches/com.apple.nsurlsessiond"] {
            #expect(throws: AppUninstallError.self) {
                try AppUninstaller.validateLeftover(fixture.home.appendingPathComponent(root), for: app, home: fixture.home.path, userCache: nil)
            }
        }
    }

    @Test(arguments: [true, false])
    func anotherInstalledCopyKeepsSharedDataOnlyWhenItsIdentifierMatches(_ sameIdentifier: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let other = try fixture.app(name: "Second App", identifier: sameIdentifier ? app.bundleIdentifier : "com.other.app")
        let support = try fixture.directory("Library/Application Support/ai.opencode.desktop")
        let result = try fixture.scan(app, installed: [app, other])

        if sameIdentifier {
            #expect(result.items.map { $0.url.path } == [app.url.path])
            #expect(result.otherInstalledCopies.map(\.path) == [other.url.path])
        } else {
            #expect(Set(result.items.map { $0.url.path }) == [app.url.path, support.path])
            #expect(result.otherInstalledCopies.isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: support.path))
    }

    @Test func containerMetadataRecognizesDerivedHelperOwnershipButRequiresReview() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let helperIdentifier = app.bundleIdentifier + ".helper"
        try fixture.embeddedHelper(in: app, identifier: helperIdentifier)
        #expect(AppUninstallIdentity(app: app).identifiers.contains(helperIdentifier))
        let helper = try fixture.directory("Library/Containers/12345678-ABCD-4567-ABCD-123456789ABC")
        let unrelated = try fixture.directory("Library/Containers/ABCDEF12-ABCD-4567-ABCD-123456789ABC")
        let prefixProduct = try fixture.directory("Library/Containers/98765432-ABCD-4567-ABCD-123456789ABC")
        for (directory, identifier) in [(helper, helperIdentifier), (unrelated, "ai.opencode.desktopplus.helper"),
                                         (prefixProduct, app.bundleIdentifier + ".OtherProduct")] {
            try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": identifier], format: .binary, options: 0)
                .write(to: directory.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        }
        let result = try fixture.scan(app)

        #expect(Set(result.items.map { $0.url.path }) == [app.url.path, helper.path])
        #expect(result.items.first { $0.url.path == helper.path }?.requiresReview == true)
        for rejected in [unrelated, prefixProduct] { #expect(!result.items.contains { $0.url.path == rejected.path }) }
    }

    @Test func blockedScanRootsAreReportedInsteadOfSilentlyLookingEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let external = fixture.root.appendingPathComponent("ExternalCaches")
        try FileManager.default.createDirectory(at: external.appendingPathComponent(app.bundleIdentifier), withIntermediateDirectories: true)
        try fixture.directory("Library")
        let cacheRoot = fixture.home.appendingPathComponent("Library/Caches")
        try FileManager.default.createSymbolicLink(at: cacheRoot, withDestinationURL: external)
        let result = try fixture.scan(app)

        #expect(result.items.map { $0.url.path } == [app.url.path])
        #expect(result.unreadablePaths.contains { $0.path == cacheRoot.path })
    }

    @Test func darwinUserCacheSelectsIdentifierChildrenAndRechecksItsRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let userCache = fixture.root.appendingPathComponent("C")
        let owned = userCache.appendingPathComponent(app.bundleIdentifier)
        let helper = userCache.appendingPathComponent(app.bundleIdentifier + ".helper")
        let neighbor = userCache.appendingPathComponent(app.bundleIdentifier + "plus")
        for directory in [owned, helper, neighbor] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let identity = AppUninstallIdentity(app: app)
        let result = try fixture.scan(app, userCache: userCache)

        #expect(Set(result.items.map { $0.url.path }) == [app.url.path, owned.path, helper.path])
        #expect(result.items.first { $0.url.path == owned.path }?.requiresReview == false)
        #expect(!result.items.contains { $0.url.path == neighbor.path })
        #expect(throws: Never.self) { try AppUninstaller.validateLeftover(owned, for: app, home: fixture.home.path, userCache: userCache, identity: identity) }
        for rejected in [userCache, neighbor] {
            #expect(throws: AppUninstallError.self) { try AppUninstaller.validateLeftover(rejected, for: app, home: fixture.home.path, userCache: userCache, identity: identity) }
        }

        // 同一 C 路径在扫描后被替换成链接，不能重新授权链接目标中的数据。
        let relocated = fixture.root.appendingPathComponent("RelocatedCache")
        try FileManager.default.moveItem(at: userCache, to: relocated)
        try FileManager.default.createSymbolicLink(at: userCache, withDestinationURL: relocated)
        let redirected = try fixture.scan(app, userCache: userCache)
        #expect(redirected.items.map { $0.url.path } == [app.url.path])
        #expect(redirected.unreadablePaths.contains { $0.path == userCache.path })
        #expect(throws: AppUninstallError.self) { try AppUninstaller.validateLeftover(owned, for: app, home: fixture.home.path, userCache: userCache, identity: identity) }
    }

    @Test func unreadableInstallationDirectoryKeepsAllResidualDataUntilCopyStatusIsKnown() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let support = try fixture.directory("Library/Application Support/ai.opencode.desktop")
        try fixture.directory(".config/opencode")
        let unknown = fixture.home.appendingPathComponent("Applications/Unreadable")

        let result = try fixture.scan(app, unreadableInstallations: [unknown])

        #expect(result.items.map { $0.url.path } == [app.url.path])
        #expect(result.unreadablePaths.map(\.path) == [unknown.path])
        #expect(result.otherInstalledCopies.isEmpty)
        #expect(FileManager.default.fileExists(atPath: support.path))
    }

    @Test func scanEvidenceRetainsHelperOwnershipForRetryAndCannotAuthorizeOtherPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let helperIdentifier = "com.vendor.helper"
        try fixture.embeddedHelper(in: app, identifier: helperIdentifier)
        let userCache = fixture.root.appendingPathComponent("C")
        let helper = userCache.appendingPathComponent(helperIdentifier)
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let scan = try fixture.scan(app, userCache: userCache)
        #expect(Set(scan.items.map { $0.url.path }) == [app.url.path, helper.path])
        #expect(scan.items.first { $0.url.path == helper.path }?.requiresReview == true)

        try FileManager.default.removeItem(at: app.url)
        #expect(!AppUninstallIdentity(app: app).identifiers.contains(helperIdentifier))
        #expect(throws: AppUninstallError.self) {
            try AppUninstaller.validateLeftover(helper, for: app, home: fixture.home.path, userCache: userCache)
        }
        #expect(throws: Never.self) {
            try AppUninstaller.validateLeftover(helper, for: app, scan: scan, home: fixture.home.path, userCache: userCache)
        }

        // 此路径虽符合 helper 的命名边界，但创建于扫描之后，不能沿用扫描证据授权。
        let newPath = userCache.appendingPathComponent(helperIdentifier + ".new")
        try FileManager.default.createDirectory(at: newPath, withIntermediateDirectories: true)
        #expect(throws: AppUninstallError.self) {
            try AppUninstaller.validateLeftover(newPath, for: app, scan: scan, home: fixture.home.path, userCache: userCache)
        }
        let other = try fixture.app(name: "Other App", identifier: "com.other.app")
        let otherScan = try fixture.scan(other, userCache: userCache)
        #expect(throws: AppUninstallError.self) {
            try AppUninstaller.validateLeftover(helper, for: app, scan: otherScan, home: fixture.home.path, userCache: userCache)
        }
        #expect(throws: AppUninstallError.self) {
            try AppUninstaller.validateLeftover(helper, for: other, scan: scan, home: fixture.home.path, userCache: userCache)
        }

        let relocated = fixture.root.appendingPathComponent("RelocatedCache")
        try FileManager.default.moveItem(at: userCache, to: relocated)
        try FileManager.default.createSymbolicLink(at: userCache, withDestinationURL: relocated)
        #expect(throws: AppUninstallError.self) {
            try AppUninstaller.validateLeftover(helper, for: app, scan: scan, home: fixture.home.path, userCache: userCache)
        }
    }
    @Test func installationIdentityIsReadFreshAfterInfoPlistChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        #expect(AppUninstaller.app(at: app.url)?.bundleIdentifier == app.bundleIdentifier)
        let info = app.url.appendingPathComponent("Contents/Info.plist")
        let metadata = ["CFBundleIdentifier": "com.example.changed", "CFBundleDisplayName": "Changed"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: info)
        #expect(AppUninstaller.app(at: app.url)?.bundleIdentifier == "com.example.changed")
    }

    @Test func realInstallationCheckDetectsCopyAndRedirectedRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(identifier: "test.copy.\(UUID().uuidString)")
        let other = try fixture.app(name: "Second", identifier: app.bundleIdentifier)
        let check = try AppUninstaller.checkOtherInstallations(of: app, home: fixture.home.path)
        #expect(check.otherInstalledCopies.contains { $0.standardizedFileURL.path == other.url.standardizedFileURL.path })
        let root = fixture.home.appendingPathComponent("Applications")
        let renamed = fixture.root.appendingPathComponent("MovedApplications")
        try FileManager.default.moveItem(at: root, to: renamed)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: renamed)
        let changed = try AppUninstaller.checkOtherInstallations(of: app, home: fixture.home.path)
        #expect(changed.unreadableDirectories.contains { $0.standardizedFileURL.path == root.standardizedFileURL.path } && changed.preservesSharedData)
    }

}
