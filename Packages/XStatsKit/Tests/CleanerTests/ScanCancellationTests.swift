// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct ScanCancellationTests {
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
