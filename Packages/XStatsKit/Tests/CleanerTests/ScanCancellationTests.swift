// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct ScanCancellationTests {
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
        var checks = 0
        #expect(throws: CancellationError.self) {
            try AppUninstaller.installedApps(in: [root], excluding: []) {
                checks += 1
                if checks == 7 { throw CancellationError() }
            }
        }
        #expect(checks == 7)
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
