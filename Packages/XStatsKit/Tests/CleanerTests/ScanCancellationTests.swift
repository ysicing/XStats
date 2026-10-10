// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct ScanCancellationTests {
    @Test func cancellationInterruptsEnhancedResidualScanWithoutPublishingPartialCandidates() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let appURL = home.appendingPathComponent("Applications/Fixture.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        for index in 0..<40 {
            let path = home.appendingPathComponent("Library/Caches/Vendor/com.example.fixture.\(index)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let app = InstalledApp(url: appURL, name: "Fixture", bundleIdentifier: "com.example.fixture", version: nil, teamIdentifier: nil)
        let identity = AppUninstallIdentity(identifiers: [app.bundleIdentifier], names: [])
        var total = 0
        let complete = try AppUninstaller.leftovers(for: app, home: home.path, identity: identity, checkCancellation: { total += 1 })
        #expect(complete.count == 41 && total > 40)
        let cancelAt = total / 2
        var checks = 0
        #expect(throws: CancellationError.self) {
            try AppUninstaller.leftovers(for: app, home: home.path, identity: identity) {
                checks += 1
                if checks == cancelAt { throw CancellationError() }
            }
        }
        #expect(checks == cancelAt)
    }

    @Test func cancellationInterruptsNestedApplicationListingWithoutPartialResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("Utilities")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20 {
            let app = nested.appendingPathComponent("Fixture-\(index).app/Contents")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "test.list.\(index)", "CFBundleName": "Fixture-\(index)"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Info.plist"))
        }
        // 先统计完整扫描的检查点，再在中途取消；不依赖检查点的具体位置。
        var total = 0
        _ = try AppUninstaller.installedApps(in: [root], excluding: []) { total += 1 }
        #expect(total > 20, "每个嵌套候选都应检查取消，实际检查 \(total) 次")
        let cancelAt = total / 2
        var checks = 0
        #expect(throws: CancellationError.self) {
            try AppUninstaller.installedApps(in: [root], excluding: []) {
                checks += 1
                if checks == cancelAt { throw CancellationError() }
            }
        }
        #expect(checks == cancelAt, "取消后不应继续遍历")
        let apps = try AppUninstaller.installedApps(in: [root], excluding: ["test.list.0"], checkCancellation: {})
        #expect(apps.count == 19 && !apps.contains { $0.bundleIdentifier == "test.list.0" })
    }

    @Test func cancelledTaskDoesNotStartApplicationListing() async {
        let scan = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try AppUninstaller.scanInstalledApps()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        #expect(await scan.value)
    }

    @Test func cancellationInterruptsDirectoryTraversalWithoutReturningPartialSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20 {
            try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("\(index)"))
        }
        var checks = 0
        #expect(throws: CancellationError.self) {
            try CleanEngine.scanAllocatedSize(of: root) {
                checks += 1
                if checks == 4 { throw CancellationError() }
            }
        }
        #expect(checks == 4)
        #expect(try CleanEngine.scanAllocatedSize(of: root) == CleanEngine.allocatedSize(of: root))
    }
}
