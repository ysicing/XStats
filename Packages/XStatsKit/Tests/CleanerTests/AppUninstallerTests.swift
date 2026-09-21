// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Testing
@testable import Cleaner

@Suite struct AppUninstallerTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func touch(_ url: URL, directory: Bool = false) throws {
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    @Test func findsLeftoversByIdentifierOnly() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let lib = home.appendingPathComponent("Library")
        let appURL = home.appendingPathComponent("Applications/Foo.app")
        try touch(appURL, directory: true)
        let app = InstalledApp(url: appURL, name: "Foo", bundleIdentifier: "com.example.foo", version: "1.0", teamIdentifier: nil)

        try touch(lib.appendingPathComponent("Application Support/Foo/data.db"))
        try touch(lib.appendingPathComponent("Application Support/com.example.foo/x"))
        try touch(lib.appendingPathComponent("Application Support/FooBar/keep"))            // 名字相近的其他应用
        try touch(lib.appendingPathComponent("Caches/com.example.foo/c"))
        try touch(lib.appendingPathComponent("Caches/com.example.foobar/keep"))             // 包名前缀相同但不是派生名
        try touch(lib.appendingPathComponent("Preferences/com.example.foo.plist"))
        try touch(lib.appendingPathComponent("Preferences/ByHost/com.example.foo.ABCD.plist"))
        try touch(lib.appendingPathComponent("Containers/com.example.foo"), directory: true)
        try touch(lib.appendingPathComponent("Group Containers/TEAM123.com.example.foo"), directory: true)
        try touch(lib.appendingPathComponent("Saved Application State/com.example.foo.savedState"), directory: true)
        try touch(lib.appendingPathComponent("LaunchAgents/com.example.foo.helper.plist"))

        let found = Set(AppUninstaller.leftovers(for: app, home: home.path).map { $0.url.lastPathComponent })
        #expect(found.contains("Foo.app"))
        #expect(found.contains("Foo"))
        #expect(found.contains("com.example.foo.plist"))
        #expect(found.contains("com.example.foo.ABCD.plist"))
        #expect(found.contains("TEAM123.com.example.foo"))
        #expect(found.contains("com.example.foo.savedState"))
        #expect(found.contains("com.example.foo.helper.plist"))
        #expect(!found.contains("FooBar"))
        #expect(!found.contains("com.example.foobar"))
    }

    @Test func refusesSystemAndOutsideApps() {
        let system = InstalledApp(url: URL(fileURLWithPath: "/System/Applications/Notes.app"), name: "Notes",
                                  bundleIdentifier: "com.apple.Notes", version: nil, teamIdentifier: nil)
        #expect(throws: AppUninstallError.systemApp) { try AppUninstaller.validate(system) }
        let elsewhere = InstalledApp(url: URL(fileURLWithPath: "/tmp/Foo.app"), name: "Foo",
                                     bundleIdentifier: "com.example.foo", version: nil, teamIdentifier: nil)
        #expect(throws: AppUninstallError.self) { try AppUninstaller.validate(elsewhere) }
        let normal = InstalledApp(url: URL(fileURLWithPath: "/Applications/Foo.app"), name: "Foo",
                                  bundleIdentifier: "com.example.foo", version: nil, teamIdentifier: nil)
        #expect(throws: Never.self) { try AppUninstaller.validate(normal) }
    }

    /// leftovers 会扫描 Preferences、Caches、Containers 等十余个目录，前缀匹配一旦放行残缺包名，
    /// 用户点一次卸载就会把 com.apple.dock.plist 在内的所有 com.* 条目移进废纸篓。
    @Test func prefixMatchRequiresThreeSegmentIdentifier() {
        #expect(!AppUninstaller.matchesIdentifier("com.apple.dock.plist", "com"))
        #expect(!AppUninstaller.matchesIdentifier("com.example.foo.plist", "com"))
        #expect(!AppUninstaller.matchesIdentifier("com.google.Chrome.plist", "com.google"))
        // 精确同名仍要能删掉，否则短包名的应用会留下自己的残留
        #expect(AppUninstaller.matchesIdentifier("com", "com"))
        #expect(AppUninstaller.matchesIdentifier("com.google", "com.google"))
    }

    @Test func prefixMatchStillFindsDerivedNames() {
        #expect(AppUninstaller.matchesIdentifier("com.example.foo", "com.example.foo"))
        #expect(AppUninstaller.matchesIdentifier("com.example.foo.plist", "com.example.foo"))
        #expect(AppUninstaller.matchesIdentifier("com.example.foo.savedState", "com.example.foo"))
        #expect(AppUninstaller.matchesIdentifier("COM.EXAMPLE.FOO.helper", "com.example.foo"))
        // 兄弟应用不能被当成残留
        #expect(!AppUninstaller.matchesIdentifier("com.example.foobar", "com.example.foo"))
        #expect(!AppUninstaller.matchesIdentifier("", "com.example.foo"))
    }

    @Test func removesDockTile() {
        let tiles: [[String: Any]] = [
            ["tile-data": ["file-data": ["_CFURLString": "file:///Applications/Foo.app/", "_CFURLStringType": 15]]],
            ["tile-data": ["file-data": ["_CFURLString": "file:///Applications/Bar.app/", "_CFURLStringType": 15]]],
        ]
        let result = AppUninstaller.removingDockTile(for: URL(fileURLWithPath: "/Applications/Foo.app"), from: tiles)
        #expect(result?.count == 1)
        #expect(AppUninstaller.removingDockTile(for: URL(fileURLWithPath: "/Applications/Baz.app"), from: tiles) == nil)
    }

    @Test func shortIdentifiersCannotSelectOtherGroupContainers() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let appURL = home.appendingPathComponent("Applications/Test.app")
        try touch(appURL, directory: true)
        for name in ["group.com.apple.example", "group.com.google.example", "TEAM.com.google", "com"] {
            try touch(home.appendingPathComponent("Library/Group Containers/" + name), directory: true)
        }
        for identifier in ["com", "com.google", "com..google"] {
            let app = InstalledApp(url: appURL, name: "Test", bundleIdentifier: identifier, version: nil, teamIdentifier: nil)
            let found = Set(AppUninstaller.leftovers(for: app, home: home.path).map { $0.url.lastPathComponent })
            #expect(found.contains("group.com.apple.example") == false)
            #expect(found.contains("group.com.google.example") == false)
            #expect(found.contains("TEAM.com.google") == false)
            if identifier == "com" { #expect(found.contains("com")) }
        }
    }
}
