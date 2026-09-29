// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AIUsage

struct LocalUsageScanCacheTests {
    @Test func revisionsInvalidateOnFileChangesAndCalendarBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.jsonl")
        try Data("one".utf8).write(to: file)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = try LocalUsageScanCache.Revision(files: [file], now: now, calendar: calendar)
        #expect(initial == (try LocalUsageScanCache.Revision(files: [file], now: now, calendar: calendar)))
        #expect(initial != (try LocalUsageScanCache.Revision(files: [], now: now, calendar: calendar)))
        #expect(initial != (try LocalUsageScanCache.Revision(files: [file], now: now.addingTimeInterval(86400), calendar: calendar)))
        calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
        #expect(initial != (try LocalUsageScanCache.Revision(files: [file], now: now, calendar: calendar)))
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // 等长原子替换也必须失效，不能只比较文件大小。
        try Data("two".utf8).write(to: file, options: .atomic)
        #expect(initial != (try LocalUsageScanCache.Revision(files: [file], now: now, calendar: calendar)))
        try Data("appended".utf8).write(to: file)
        #expect(initial != (try LocalUsageScanCache.Revision(files: [file], now: now, calendar: calendar)))
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) {
            try LocalUsageScanCache.Revision(files: [file], now: now, calendar: calendar)
        }
    }
}
