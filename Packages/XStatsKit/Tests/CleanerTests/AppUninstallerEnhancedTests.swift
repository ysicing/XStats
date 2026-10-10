// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Testing
@testable import Cleaner

@Suite struct AppUninstallerEnhancedTests {
    private struct Fixture {
        let root: URL
        let home: URL
        let outside: URL

        init() throws {
            let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-enhanced-\(UUID().uuidString)")
            root = rootURL
            home = rootURL.appendingPathComponent("Home")
            outside = rootURL.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func app(name: String = "Foo", identifier: String = "com.example.foo") throws -> InstalledApp {
            let url = home.appendingPathComponent("Applications/\(name).app")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return InstalledApp(url: url, name: name, bundleIdentifier: identifier, version: nil, teamIdentifier: nil)
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
            try Data("test data".utf8).write(to: url)
            return url
        }

        func metadata(_ identifier: String, in directory: URL) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": identifier], format: .binary, options: 0)
            try data.write(to: directory.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        }

        func symlink(_ relative: String, to destination: URL) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
            return url
        }
    }

    @Test func containerMetadataDeterminesOwnershipEvenForUUIDDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let owned = try fixture.directory("Library/Containers/12345678-ABCD-4567-ABCD-123456789ABC")
        try fixture.metadata(app.bundleIdentifier, in: owned)
        let unrelated = try fixture.directory("Library/Containers/ABCDEF12-3456-4567-ABCD-123456789ABC")
        try fixture.metadata("com.other.app", in: unrelated)
        let misleadingName = try fixture.directory("Library/Containers/com.example.foo")
        try fixture.metadata("com.other.app", in: misleadingName)
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier], names: [])

        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)

        #expect(Set(found.map { $0.url.path }) == Set([app.url.path, owned.path]))
        #expect(found.first { $0.url.path == owned.path }?.requiresReview == false)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: misleadingName.path))
    }

    @Test func verifiedEmbeddedIdentifiersFindTheirOwnResidualData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let helperIdentifier = "com.vendor.separate-helper"
        let preference = try fixture.file("Library/Preferences/\(helperIdentifier).plist")
        let cache = try fixture.directory("Library/Caches/\(helperIdentifier)")
        let unrelated = try fixture.file("Library/Preferences/com.vendor.separate-helper-other.plist")
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier, helperIdentifier], names: [])

        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)

        #expect(Set(found.map { $0.url.path }) == Set([app.url.path, preference.path, cache.path]))
        #expect(!found.contains { $0.url.path == unrelated.path })
    }

    @Test func sentryBundleNameCandidateRequiresReviewAndDoesNotMatchSimilarNames() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(name: "Localized Display Name")
        let namedCache = try fixture.directory("Library/Caches/SentryCrash/Foo")
        let similarlyNamed = try fixture.directory("Library/Caches/SentryCrash/FooBar")
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier], names: ["Foo"])

        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)

        #expect(Set(found.map { $0.url.path }) == Set([app.url.path, namedCache.path]))
        #expect(found.first { $0.url.path == namedCache.path }?.requiresReview == true)
        #expect(!found.contains { $0.url.path == similarlyNamed.path })
    }

    @Test func nestedVendorEntriesPreserveVendorRootsAndOtherApplications() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // A coincidental app name must not make a shared vendor root selectable.
        let app = try fixture.app(name: "Microsoft")
        let support = try fixture.directory("Library/Application Support/Microsoft/com.example.foo")
        let cache = try fixture.directory("Library/Caches/Microsoft/com.example.foo.cache")
        let log = try fixture.file("Library/Logs/Microsoft/com.example.foo.log")
        let neighbors = [
            try fixture.directory("Library/Application Support/Microsoft/com.other.app"),
            try fixture.directory("Library/Caches/Microsoft/com.example.foobar"),
            try fixture.file("Library/Logs/Microsoft/com.other.app.log"),
        ]
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier], names: ["Microsoft"])

        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)

        #expect(Set(found.map { $0.url.path }) == Set([app.url.path, support.path, cache.path, log.path]))
        for relative in ["Library/Application Support/Microsoft", "Library/Caches/Microsoft", "Library/Logs/Microsoft"] {
            let parent = fixture.home.appendingPathComponent(relative)
            #expect(!found.contains { $0.url.path == parent.path })
            #expect(FileManager.default.fileExists(atPath: parent.path))
        }
        for neighbor in neighbors { #expect(!found.contains { $0.url.path == neighbor.path }) }
    }

    @Test func vscodeChannelsKeepDistinctDataAndRequireReviewForSharedData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stable = try fixture.app(name: "Visual Studio Code", identifier: "com.microsoft.VSCode")
        let insiders = try fixture.app(name: "Visual Studio Code - Insiders", identifier: "com.microsoft.VSCodeInsiders")
        let stableData = try fixture.directory("Library/Application Support/Code")
        let insidersData = try fixture.directory("Library/Application Support/Code - Insiders")
        let stableExtensions = try fixture.directory(".vscode")
        let insidersExtensions = try fixture.directory(".vscode-insiders")
        let shared = try fixture.directory(".vscode-shared")

        let stableFound = AppUninstaller.leftovers(for: stable, home: fixture.home.path,
            identity: AppUninstallIdentity(identifiers: [stable.bundleIdentifier], names: []))
        let insidersFound = AppUninstaller.leftovers(for: insiders, home: fixture.home.path,
            identity: AppUninstallIdentity(identifiers: [insiders.bundleIdentifier], names: []))

        #expect(Set(stableFound.map { $0.url.path }) == Set([stable.url.path, stableData.path, stableExtensions.path, shared.path]))
        #expect(Set(insidersFound.map { $0.url.path }) == Set([insiders.url.path, insidersData.path, insidersExtensions.path, shared.path]))
        #expect(stableFound.first { $0.url.path == shared.path }?.requiresReview == true)
        #expect(insidersFound.first { $0.url.path == shared.path }?.requiresReview == true)
        #expect(stableFound.first { $0.url.path == stableData.path }?.requiresReview == false)
        #expect(insidersFound.first { $0.url.path == insidersData.path }?.requiresReview == false)
    }

    @Test func applicationGroupsUseExactEntitlementsAndKeepReviewWhenIdentifiersAlsoMatch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let groupIdentifier = "TEAM123.com.vendor.shared"
        let group = try fixture.directory("Library/Group Containers/\(groupIdentifier)")
        let uuidGroup = try fixture.directory("Library/Group Containers/ABCDEF12-3456-4567-ABCD-123456789ABC")
        try fixture.metadata(groupIdentifier, in: uuidGroup)
        let unrelated = try fixture.directory("Library/Group Containers/TEAM123.com.vendor.other")
        let scriptsIdentifier = "com.example.foo.shared"
        let scripts = try fixture.directory("Library/Application Scripts/\(scriptsIdentifier)")
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier], names: [],
            applicationGroups: [groupIdentifier, scriptsIdentifier])

        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)

        #expect(Set(found.map { $0.url.path }) == Set([app.url.path, group.path, uuidGroup.path, scripts.path]))
        for candidate in [group, uuidGroup, scripts] {
            #expect(found.first { $0.url.path == candidate.path }?.requiresReview == true)
        }
        #expect(!found.contains { $0.url.path == unrelated.path })
    }

    @Test(arguments: ["scanRoot", "vendorParent", "leaf"])
    func symlinkRedirectsCannotEscapeFromAnyLevelOfTheScan(_ level: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let externalTarget = fixture.outside.appendingPathComponent(app.bundleIdentifier)
        try FileManager.default.createDirectory(at: externalTarget, withIntermediateDirectories: true)
        try Data("must be preserved".utf8).write(to: externalTarget.appendingPathComponent("keep"))
        let redirectedCandidate: URL
        switch level {
        case "scanRoot":
            let root = try fixture.symlink("Library/Caches", to: fixture.outside)
            redirectedCandidate = root.appendingPathComponent(app.bundleIdentifier)
        case "vendorParent":
            let parent = try fixture.symlink("Library/Caches/Vendor", to: fixture.outside)
            redirectedCandidate = parent.appendingPathComponent(app.bundleIdentifier)
        default:
            redirectedCandidate = try fixture.symlink("Library/Caches/\(app.bundleIdentifier)", to: externalTarget)
        }
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier], names: [])

        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)

        #expect(Set(found.map { $0.url.path }) == Set([app.url.path]))
        #expect(throws: AppUninstallError.self) {
            try AppUninstaller.validateLeftover(redirectedCandidate, for: app, home: fixture.home.path)
        }
        #expect(FileManager.default.fileExists(atPath: externalTarget.appendingPathComponent("keep").path))
    }

    @Test func validatesAgainWhenAParentIsReplacedAfterScanning() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let candidate = try fixture.directory("Library/Caches/Vendor/com.example.foo")
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier], names: [])
        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)
        #expect(found.contains { $0.url.path == candidate.path })
        #expect(throws: Never.self) { try AppUninstaller.validateLeftover(candidate, for: app, home: fixture.home.path) }

        try FileManager.default.removeItem(at: candidate.deletingLastPathComponent())
        let externalTarget = fixture.outside.appendingPathComponent(app.bundleIdentifier)
        try FileManager.default.createDirectory(at: externalTarget, withIntermediateDirectories: true)
        _ = try fixture.symlink("Library/Caches/Vendor", to: fixture.outside)

        #expect(throws: AppUninstallError.self) {
            try AppUninstaller.validateLeftover(candidate, for: app, home: fixture.home.path)
        }
        #expect(FileManager.default.fileExists(atPath: externalTarget.path))
    }

    @Test func knownApplicationDataReplacesItsAlreadyFoundChildren() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(name: "Visual Studio Code", identifier: "com.microsoft.VSCode")
        let support = try fixture.directory("Library/Application Support/Code")
        let child = try fixture.directory("Library/Application Support/Code/com.microsoft.VSCode.cache")
        try fixture.file("Library/Application Support/Code/com.microsoft.VSCode.cache/data")
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier], names: [])

        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)

        #expect(Set(found.map { $0.url.path }) == Set([app.url.path, support.path]))
        #expect(!found.contains { $0.url.path == child.path })
        #expect(found.count == Set(found.map { $0.url.path }).count)
    }

    @Test func sharedScanRootsCannotBeSelectedEvenWhenTheirNamesMatchTheApp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let sharedRoots = [
            "Library/Application Support/Microsoft",
            "Library/Application Support/JetBrains",
            "Library/Application Support/CrashReporter",
            "Library/Caches/SentryCrash",
            "Library/Caches/org.sparkle-project.Sparkle",
            "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
            "Library/Preferences/ByHost",
            "Library/Logs/DiagnosticReports",
        ]
        for path in sharedRoots { try fixture.directory(path) }
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier],
            names: ["Microsoft", "JetBrains", "CrashReporter", "SentryCrash", "org.sparkle-project.Sparkle"])

        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)

        #expect(Set(found.map { $0.url.path }) == Set([app.url.path]))
        for path in sharedRoots + ["Library/Caches", "Library/Application Support"] {
            let url = fixture.home.appendingPathComponent(path)
            #expect(throws: AppUninstallError.self) {
                try AppUninstaller.validateLeftover(url, for: app, home: fixture.home.path)
            }
        }
    }

    @Test func nameCandidatesRequireReviewAndParentsInheritReviewFromChildren() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app(name: "Visual Studio Code", identifier: "com.microsoft.VSCode")
        let namedSupport = try fixture.directory("Library/Application Support/Named Data")
        let namedLogs = try fixture.directory("Library/Logs/Named Logs")
        let applicationData = try fixture.directory("Library/Application Support/Code")
        let child = try fixture.directory("Library/Application Support/Code/com.vendor.shared-helper")
        let primaryPreference = try fixture.file("Library/Preferences/com.microsoft.VSCode.plist")
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier, "com.vendor.shared-helper"],
            names: ["Named Data", "Named Logs"])

        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)

        #expect(Set(found.map { $0.url.path }) == Set([app.url.path, namedSupport.path, namedLogs.path,
            applicationData.path, primaryPreference.path]))
        for candidate in [namedSupport, namedLogs, applicationData] {
            #expect(found.first { $0.url.path == candidate.path }?.requiresReview == true)
        }
        #expect(found.first { $0.url.path == primaryPreference.path }?.requiresReview == false)
        #expect(!found.contains { $0.url.path == child.path })
    }

    @Test func applicationRootReplacedAfterScanningCannotAuthorizeAnOutsideApplication() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let app = try fixture.app()
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier], names: [])
        let found = AppUninstaller.leftovers(for: app, home: fixture.home.path, identity: identity)
        #expect(found.contains { $0.url.path == app.url.path && $0.kind == .application })

        try FileManager.default.removeItem(at: app.url.deletingLastPathComponent())
        let externalApplication = fixture.outside.appendingPathComponent(app.url.lastPathComponent)
        try FileManager.default.createDirectory(at: externalApplication, withIntermediateDirectories: true)
        let preserved = externalApplication.appendingPathComponent("keep")
        try Data("another application's data".utf8).write(to: preserved)
        _ = try fixture.symlink("Applications", to: fixture.outside)

        #expect(throws: AppUninstallError.self) {
            try AppUninstaller.validate(app, home: fixture.home.path)
        }
        #expect(throws: AppUninstallError.self) {
            try AppUninstaller.validateLeftover(app.url, for: app, home: fixture.home.path)
        }
        #expect(FileManager.default.fileExists(atPath: preserved.path))
    }
}
