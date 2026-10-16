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
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-10 * 86400)], ofItemAtPath: live.directory.path)
    var stale: [URL] = []
    for index in 0..<4 {
      let folder = root.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent("segment.mov"))
      try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-Double(5 - index) * 86400)],
        ofItemAtPath: folder.path)
      stale.append(folder)
    }
    let recent = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
    let unrelated = root.appendingPathComponent("user-folder")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    try await RecordingMedia.cleanStaleSessions(
      root: root, now: now, maximumAge: 3 * 86400, maximumBytes: 64, maximumSessions: 2)
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
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-10 * 86400)], ofItemAtPath: directory.path)
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
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-5 * 86400)], ofItemAtPath: directory.path)
    try await RecordingMedia.cleanStaleSessions(root: root, now: now)
    #expect(FileManager.default.fileExists(atPath: directory.path))
    try await RecordingMedia.cleanStaleSessions(root: root, now: now.addingTimeInterval(3 * 86400))
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test func manualCleanupCountsButProtectsLiveAndRecentMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let live = try RecordingMedia(root: root)
    try Data(repeating: 0, count: 256).write(to: live.newSegmentURL())
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-86400)], ofItemAtPath: live.directory.path)
    let recent = root.appendingPathComponent(UUID().uuidString)
    let unused = root.appendingPathComponent(UUID().uuidString)
    for directory in [recent, unused] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(repeating: 1, count: 128).write(to: directory.appendingPathComponent("segment.mov"))
    }
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-3601)], ofItemAtPath: unused.path)
    let snapshot = try await CaptureCache.manage(root: root, now: now, policy: .inspect)
    #expect(snapshot.usage.totalBytes == 512)
    #expect(snapshot.usage.reclaimableBytes == 128)
    #expect(snapshot.usage.reclaimableSessions == 1)
    #expect(snapshot.removedSessions == 0)
    #expect(FileManager.default.fileExists(atPath: unused.path))
    let report = try await CaptureCache.manage(root: root, now: now, policy: .unused)
    #expect(report.removedSessions == 1)
    #expect(report.removedBytes == 128)
    #expect(report.usage.totalBytes == 384)
    #expect(report.usage.reclaimableSessions == 0)
    #expect(FileManager.default.fileExists(atPath: live.directory.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(!FileManager.default.fileExists(atPath: unused.path))
    let repeated = try await CaptureCache.manage(root: root, now: now, policy: .unused)
    #expect(repeated.removedSessions == 0)
    try await live.discard()
  }
  @Test func cleanupDoesNotFollowLinksOrRemoveUnrelatedFiles() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Recordings")
    let outside = base.appendingPathComponent("saved")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let saved = outside.appendingPathComponent("user.mp4")
    try Data([1, 2, 3]).write(to: saved)
    let unrelated = root.appendingPathComponent("notes.txt")
    try Data([4]).write(to: unrelated)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent(UUID().uuidString), withDestinationURL: outside)
    let report = try await CaptureCache.manage(root: root, policy: .unused)
    #expect(report.usage.totalBytes == 0)
    #expect(report.removedSessions == 0)
    #expect(try Data(contentsOf: saved) == Data([1, 2, 3]))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    let alias = base.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    await #expect(throws: (any Error).self) {
      try await CaptureCache.manage(root: alias, policy: .unused)
    }
  }
  @Test func missingCacheIsEmptyAndCancellationDoesNotRemoveMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = try await CaptureCache.manage(root: root, policy: .inspect)
    #expect(empty.usage.totalBytes == 0)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let media = try RecordingMedia(root: root)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: media.directory.path)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await CaptureCache.manage(root: root, policy: .unused)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(FileManager.default.fileExists(atPath: media.directory.path))
    try await media.discard()
  }

}
