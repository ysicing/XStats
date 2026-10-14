// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import CaptureCore

@Suite struct RecordingCacheTests {
    @Test func staleCachesAreBoundedWithoutRemovingLiveSessionsOrRecentCrashData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = try RecordingMedia(root: root)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 86400)], ofItemAtPath: live.directory.path)
        var stale: [URL] = []
        for index in 0..<4 {
            let folder = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent("segment.mov"))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(5 - index) * 86400)], ofItemAtPath: folder.path)
            stale.append(folder)
        }
        let recent = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("user-folder")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try await RecordingMedia.cleanStaleSessions(root: root, now: now, maximumAge: 3 * 86400, maximumBytes: 64, maximumSessions: 2)
        #expect(FileManager.default.fileExists(atPath: live.directory.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(stale.prefix(3).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: stale[3].path))
        try await live.discard()
    }
    @Test func crashedSessionBecomesEligibleAfterItsLeaseIsReleased() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var media: RecordingMedia? = try RecordingMedia(root: root)
        let directory = try #require(media).directory
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 86400)], ofItemAtPath: directory.path)
        try await RecordingMedia.cleanStaleSessions(root: root, now: now)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        media = nil
        try await RecordingMedia.cleanStaleSessions(root: root, now: now)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    @Test func sweepingLegacyCacheDoesNotRefreshItsRetentionAge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5 * 86400)], ofItemAtPath: directory.path)
        try await RecordingMedia.cleanStaleSessions(root: root, now: now)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        try await RecordingMedia.cleanStaleSessions(root: root, now: now.addingTimeInterval(3 * 86400))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

}
