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
        let helper = try fixture.directory("Library/Containers/" + helperIdentifier)
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

    @Test func brokenAppAndReadableLinkedDirectoryDoNotMarkInstallationCheckIncomplete() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(identifier: "test.entries.\(UUID().uuidString)")
        try fixture.directory("Applications/Broken.app/Contents")
        let elsewhere = fixture.root.appendingPathComponent("Store")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent("Applications/Nix Apps"), withDestinationURL: elsewhere)
        let check = try AppUninstaller.checkOtherInstallations(of: app, home: fixture.home.path)
        #expect(check.unreadableDirectories.isEmpty, "损坏应用与可读的空链接目录不影响副本检查：\(check.unreadableDirectories)")
        #expect(check.otherInstalledCopies.isEmpty && !check.preservesSharedData)
    }

    @Test(arguments: [0, 0o111], [false, true])
    func unreadableInstallationSubdirectoryPreservesSharedData(permissions: Int, linked: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(identifier: "test.permissions.\(UUID().uuidString)")
        let copy = try fixture.app(name: "Private/Second", identifier: app.bundleIdentifier)
        let privateDirectory = copy.url.deletingLastPathComponent()
        let entry = fixture.home.appendingPathComponent("Applications/Private")
        let directory: URL
        if linked {
            directory = fixture.root.appendingPathComponent("Store")
            try FileManager.default.moveItem(at: entry, to: directory)
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: directory)
        } else {
            directory = privateDirectory
        }
        try fixture.file("Library/Caches/\(app.bundleIdentifier)/state")
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        #expect(throws: (any Error).self) {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        }
        if permissions == 0o111 {
            #expect(AppUninstaller.app(at: directory.appendingPathComponent("Second.app")) != nil,
                    "不能列出目录仍可按已知路径读取副本身份")
        }
        let check = try AppUninstaller.checkOtherInstallations(of: app, home: fixture.home.path)
        #expect(check.preservesSharedData)
        #expect(check.unreadableDirectories.contains { $0.standardizedFileURL.path == entry.standardizedFileURL.path })
        let scan = try AppUninstaller.scanLeftoversReport(for: app, home: fixture.home.path)
        #expect(scan.installationCheckIncomplete)
        #expect(scan.items.map(\.kind) == [.application])
        let listed = try AppUninstaller.installedApps(in: [fixture.home.appendingPathComponent("Applications")],
                                                    excluding: [], checkCancellation: {})
        #expect(listed.map(\.bundleIdentifier) == [app.bundleIdentifier])
    }

    @Test func symlinkedInstallationOfSameIdentifierCountsAsCopyButIsNotListed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(identifier: "test.linked.\(UUID().uuidString)")
        let store = fixture.root.appendingPathComponent("Store/Linked.app/Contents")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": app.bundleIdentifier], format: .xml, options: 0)
            .write(to: store.appendingPathComponent("Info.plist"))
        let linkedFolder = fixture.home.appendingPathComponent("Applications/Nix Apps")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: store.deletingLastPathComponent().deletingLastPathComponent())
        let check = try AppUninstaller.checkOtherInstallations(of: app, home: fixture.home.path)
        #expect(check.otherInstalledCopies.count == 1 && check.preservesSharedData, "链接目录中的同标识副本必须保留共用数据")
        let listed = try AppUninstaller.installedApps(in: [fixture.home.appendingPathComponent("Applications")], excluding: [], checkCancellation: {})
        #expect(listed.map(\.bundleIdentifier) == [app.bundleIdentifier], "可卸载列表不应展示链接安装")
        #expect(check.otherInstalledCopies.map(\.path).allSatisfy { $0.hasSuffix("/Home/Applications/Nix Apps/Linked.app") },
                "副本路径应是安装目录里的条目，而不是链接目标：\(check.otherInstalledCopies)")
    }

    @Test(arguments: ["Info.plist", "Contents"])
    func copyWithReadableSymlinkedMetadataKeepsInstallationCheckIncomplete(_ linked: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(identifier: "test.linkedplist.\(UUID().uuidString)")
        let copy = try fixture.app(name: "Linked", identifier: app.bundleIdentifier)
        // 链接目标可读且标识与所选应用一致；严格读取拒绝链接，但不能据此判定没有副本。
        let contents = copy.url.appendingPathComponent("Contents")
        let original = linked == "Info.plist" ? contents.appendingPathComponent("Info.plist") : contents
        let moved = fixture.root.appendingPathComponent("Elsewhere-\(linked)")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
        #expect(AppUninstaller.app(at: copy.url) == nil, "严格读取应拒绝链接的元数据")
        let check = try AppUninstaller.checkOtherInstallations(of: app, home: fixture.home.path)
        #expect(check.unreadableDirectories.map { $0.resolvingSymlinksInPath().path } == [copy.url.resolvingSymlinksInPath().path],
                "无法确认身份的副本必须触发共用数据保护：\(check.unreadableDirectories)")
        #expect(check.preservesSharedData)
    }

    @Test(arguments: ["missing", "corrupt", "noIdentifier"])
    func definitelyInvalidBundleDoesNotMarkInstallationCheckIncomplete(_ kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(identifier: "test.invalid.\(UUID().uuidString)")
        let broken = try fixture.directory("Applications/Broken.app/Contents")
        let info = broken.appendingPathComponent("Info.plist")
        switch kind {
        case "corrupt": try Data("not a plist".utf8).write(to: info)
        case "noIdentifier":
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Broken"], format: .xml, options: 0).write(to: info)
        default: break
        }
        let check = try AppUninstaller.checkOtherInstallations(of: app, home: fixture.home.path)
        #expect(check.unreadableDirectories.isEmpty, "确定无效的条目不是可运行副本：\(kind)")
    }

    @Test func copyWithUnreadableInfoPlistKeepsInstallationCheckIncomplete() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(identifier: "test.plist.\(UUID().uuidString)")
        let copy = try fixture.app(name: "Updating", identifier: app.bundleIdentifier)
        let info = copy.url.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: info.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: info.path) }
        let check = try AppUninstaller.checkOtherInstallations(of: app, home: fixture.home.path)
        #expect(check.unreadableDirectories.map { $0.resolvingSymlinksInPath().path } == [copy.url.resolvingSymlinksInPath().path], "存在但不可读的 Info.plist 不能当作没有副本")
        #expect(check.preservesSharedData)
    }

    @Test func differentlyCasedPathsRespectVolumeSemantics() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(identifier: "test.case.\(UUID().uuidString)")
        let caseSensitive = try #require(fixture.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames)
        if caseSensitive {
            let other = try fixture.app(name: "OPENCODE", identifier: app.bundleIdentifier)
            #expect(!AppUninstaller.isSameItem(app.url, other.url))
            let check = try AppUninstaller.checkOtherInstallations(of: app, home: fixture.home.path)
            #expect(check.otherInstalledCopies.contains { $0.standardizedFileURL.path == other.url.standardizedFileURL.path })
            #expect(check.preservesSharedData)
            return
        }
        let recased = InstalledApp(url: app.url.deletingLastPathComponent().appendingPathComponent("OPENCODE.app"),
                                   name: app.name, bundleIdentifier: app.bundleIdentifier, version: nil, teamIdentifier: nil)
        try #require(FileManager.default.fileExists(atPath: recased.url.path))
        #expect(AppUninstaller.isSameItem(app.url, recased.url))
        let check = try AppUninstaller.checkOtherInstallations(of: recased, home: fixture.home.path)
        #expect(check.otherInstalledCopies.isEmpty, "大小写不同的同一路径被误判为副本：\(check.otherInstalledCopies)")
    }

    @Test func singleComponentIdentifierAppIsStillListed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(name: "MyTool", identifier: "MyTool")
        #expect(AppUninstaller.app(at: app.url)?.bundleIdentifier == "MyTool")
        let traversal = try fixture.app(name: "Evil", identifier: "../Library")
        #expect(AppUninstaller.app(at: traversal.url) == nil, "含路径分隔符的标识不能进入残留路径拼接")
    }

    @Test func singleComponentIdentifierMatchesRequireReview() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(name: "Tool", identifier: "Code")
        let shared = try fixture.directory("Library/Application Support/Code")
        let cache = try fixture.directory("Library/Caches/Code")
        let result = try fixture.scan(app)
        let matched = result.items.filter { [shared.path, cache.path].contains($0.url.path) }
        let paths = result.items.map(\.url.path)
        let allReview = matched.allSatisfy(\.requiresReview)
        #expect(matched.count == 2, "单段标识仍可列出自己的同名条目：\(paths)")
        #expect(allReview, "单段标识的同名条目可能是共用目录，不能默认勾选")
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
