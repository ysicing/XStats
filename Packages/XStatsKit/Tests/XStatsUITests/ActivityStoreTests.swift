// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import XStatsUI

struct ActivityStoreTests {
  private enum FixtureFailure: Error {
    case unexpectedKeyAccess
    case sqlite(Int32)
  }

  private static let fixtureKey = SymmetricKey(data: Data(repeating: 0xA5, count: 32))

  @Test func fileRoundTripKeepsFirstSessionAndListsDistinctDevices() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = ActivityStore(url: url, keyProvider: { Self.fixtureKey })
    #expect(!FileManager.default.fileExists(atPath: url.path))

    let deviceID = UUID()
    let original = session(deviceID: deviceID, start: 60.125, end: 120.25, appName: "编辑器 'Pro'")
    let later = session(deviceID: deviceID, start: 180, end: 240, category: "communication")
    let conflicting = session(
      id: original.id, start: 70, end: 100, appName: "Replacement", category: "browsing")
    try await store.insert([later, original, conflicting])
    try await store.insert([conflicting, original])

    let reopened = ActivityStore(url: url, keyProvider: { Self.fixtureKey })
    let interval = DateInterval(start: date(0), end: date(300))
    #expect(try await reopened.sessions(in: interval) == [original, later])
    #expect(try await reopened.deviceIDs() == [deviceID])
    #expect(try await reopened.localDays(deviceID: deviceID) == ["2001-01-01"])
    #expect(try await reopened.exportDay("2001-01-01", deviceID: deviceID) == [original, later])
  }

  @Test func aMissingDatabaseCanBeReadWithoutAccessingTheKey() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = ActivityStore(url: url, keyProvider: { throw FixtureFailure.unexpectedKeyAccess })
    let record = session(start: 1, end: 2)
    let interval = DateInterval(start: date(0), end: date(3))
    #expect(try await store.sessions(in: interval).isEmpty)
    #expect(try await store.sessions(in: interval, including: [record]) == [record])
    #expect(try await store.deviceIDs().isEmpty)
    #expect(try await store.localDays(deviceID: record.deviceID).isEmpty)
    #expect(try await store.exportDay("2001-01-01", deviceID: record.deviceID).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
  }

  @Test func aWriteCanResumeAnInterruptedDatabaseCreation() async throws {
    let url = temporaryURL()
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: url)

    let reader = ActivityStore(url: url, keyProvider: { throw FixtureFailure.unexpectedKeyAccess })
    #expect(try await reader.deviceIDs().isEmpty)
    let writer = ActivityStore(url: url, keyProvider: { Self.fixtureKey })
    let record = session(start: 1, end: 2)
    try await writer.insert([record])

    let reopened = ActivityStore(url: url, keyProvider: { Self.fixtureKey })
    #expect(try await reopened.deviceIDs() == [record.deviceID])
  }

  @Test func theWrongKeyCannotReadOrWriteAnExistingDatabase() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let record = session(start: 1, end: 2)
    let store = ActivityStore(url: url, keyProvider: { Self.fixtureKey })
    try await store.insert([record])

    let other = ActivityStore(
      url: url, keyProvider: { SymmetricKey(data: Data(repeating: 0x5A, count: 32)) })
    let interval = DateInterval(start: date(0), end: date(3))
    await #expect(throws: ActivityStore.Failure.authentication) {
      try await other.sessions(in: interval)
    }
    let newRecord = session(start: 1, end: 2)
    await #expect(throws: ActivityStore.Failure.authentication) {
      try await other.insert([newRecord])
    }

    let reopened = ActivityStore(url: url, keyProvider: { Self.fixtureKey })
    #expect(try await reopened.sessions(in: interval) == [record])
  }

  @Test(arguments: [
    "UPDATE activity_records SET ciphertext = zeroblob(length(ciphertext))",
    "UPDATE activity_records SET day_key = zeroblob(32)",
    "UPDATE activity_ranges SET device_key = zeroblob(32)",
    "UPDATE activity_ranges SET bucket = (SELECT min(bucket) FROM activity_ranges)",
    "PRAGMA ignore_check_constraints = ON; "
      + "UPDATE activity_records SET ciphertext = zeroblob(16385)",
  ])
  func tamperedRecordsAndIndexesFailAuthentication(_ sql: String) async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = ActivityStore(url: url, keyProvider: { Self.fixtureKey })
    try await store.insert([session(start: 1, end: 2), session(start: 86_401, end: 86_402)])
    try execute(sql, on: url)

    let interval = DateInterval(start: date(0), end: date(86_403))
    await #expect(throws: ActivityStore.Failure.authentication) {
      try await store.sessions(in: interval)
    }
  }

  @Test func plaintextRecordFieldsAreAbsentFromTheDatabaseAndWAL() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = ActivityStore(url: url, keyProvider: { Self.fixtureKey })
    let deviceName = "fixture-laptop (MacBook Air)"
    var record = session(
      start: 782_348_765.125, end: 782_349_024.875, appName: "机密应用 XStats-plaintext-probe")
    record.deviceName = deviceName
    try await store.insert([record])

    let wal = URL(fileURLWithPath: url.path + "-wal")
    let walBytes = try Data(contentsOf: wal)
    #expect(!walBytes.isEmpty)
    try execute("PRAGMA wal_checkpoint(FULL)", on: url)
    let dbBytes = try Data(contentsOf: url)
    withExtendedLifetime(store) {}

    let utc = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
    var needles = [
      record.appID, record.appName, record.id.uuidString, record.deviceID.uuidString,
      record.start.formatted(utc), deviceName,
    ].map { Data($0.utf8) }
    for date in [record.start, record.end] {
      var bits = date.timeIntervalSinceReferenceDate.bitPattern.bigEndian
      needles.append(withUnsafeBytes(of: &bits) { Data($0) })
    }
    for needle in needles {
      #expect(dbBytes.range(of: needle) == nil)
      #expect(walBytes.range(of: needle) == nil)
    }
  }

  @Test func aPlaintextSchemaIsRejectedWithoutAccessingTheKeyOrChangingTheFile() async throws {
    let url = temporaryURL()
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try execute(
      """
      CREATE TABLE activity_sessions (id TEXT PRIMARY KEY, app_id TEXT);
      INSERT INTO activity_sessions VALUES ('legacy-id', 'legacy-record');
      """, on: url)
    let original = try Data(contentsOf: url)
    let store = ActivityStore(url: url, keyProvider: { throw FixtureFailure.unexpectedKeyAccess })

    await #expect(throws: ActivityStore.Failure.unsupportedSchema) {
      try await store.deviceIDs()
    }
    let record = session(start: 1, end: 2)
    await #expect(throws: ActivityStore.Failure.unsupportedSchema) {
      try await store.insert([record])
    }
    #expect(try Data(contentsOf: url) == original)
  }

  @Test func intervalFiltersByDeviceAndReturnsWholeIntersectingSessions() async throws {
    let store = ActivityStore(url: nil)
    let deviceID = UUID()
    let otherDeviceID = UUID()
    let endingAtStart = session(deviceID: deviceID, start: 0, end: 10)
    let overlapsStart = session(deviceID: deviceID, start: 5, end: 15)
    let exact = session(deviceID: deviceID, start: 10, end: 20)
    let otherDevice = session(deviceID: otherDeviceID, start: 12, end: 18)
    let overlapsEnd = session(deviceID: deviceID, start: 15, end: 25)
    let startingAtEnd = session(deviceID: deviceID, start: 20, end: 30)
    try await store.insert(
      [startingAtEnd, overlapsEnd, otherDevice, exact, overlapsStart, endingAtStart])

    let interval = DateInterval(start: date(10), end: date(20))
    let allDevices = try await store.sessions(in: interval)
    #expect(allDevices == [overlapsStart, exact, otherDevice, overlapsEnd])
    let matchingDevice = try await store.sessions(in: interval, deviceID: deviceID)
    #expect(matchingDevice == [overlapsStart, exact, overlapsEnd])
    #expect(try await store.sessions(in: interval, deviceID: otherDeviceID) == [otherDevice])
    #expect(try await store.sessions(in: interval, deviceID: UUID()).isEmpty)

    let emptyInterval = DateInterval(start: date(15), duration: 0)
    #expect(try await store.sessions(in: emptyInterval).isEmpty)
    #expect(try await store.sessions(in: emptyInterval, deviceID: deviceID).isEmpty)
  }

  @Test func indexedAndWideQueriesFindLongSessionsWithoutDuplicatingMultidayMatches() async throws {
    let store = ActivityStore(url: nil)
    let deviceID = UUID()
    let long = session(deviceID: deviceID, start: -400 * 86_400, end: 400 * 86_400)
    let crossesMidnight = session(deviceID: deviceID, start: -1, end: 1)
    let otherDevice = session(start: -1, end: 1)
    try await store.insert([long, crossesMidnight, otherDevice])

    let narrow = DateInterval(start: date(-10), end: date(10))
    let narrowMatches = try await store.sessions(in: narrow, deviceID: deviceID)
    #expect(narrowMatches == [long, crossesMidnight])
    let late = DateInterval(start: date(399 * 86_400), duration: 60)
    #expect(try await store.sessions(in: late, deviceID: deviceID) == [long])
    let wide = DateInterval(start: date(-200 * 86_400), end: date(200 * 86_400))
    #expect(try await store.sessions(in: wide, deviceID: deviceID) == [long, crossesMidnight])
  }

  @Test func recentSessionsAreFilteredAndDeduplicatedAgainstStoredSessions() async throws {
    let store = ActivityStore(url: nil)
    let deviceID = UUID()
    let otherDeviceID = UUID()
    let saved = session(deviceID: deviceID, start: 12, end: 14)
    try await store.insert([saved])

    let pending = session(deviceID: deviceID, start: 5, end: 11)
    let ongoing = session(deviceID: deviceID, start: 17, end: 24)
    let otherDevice = session(deviceID: otherDeviceID, start: 14, end: 16)
    let stale = session(id: saved.id, deviceID: deviceID, start: 8, end: 19)
    let duplicate = session(id: pending.id, deviceID: deviceID, start: 6, end: 17)
    let recent = [
      ongoing, pending, stale, otherDevice, duplicate,
      session(deviceID: deviceID, start: 0, end: 10),
      session(deviceID: deviceID, start: 20, end: 30),
      session(deviceID: deviceID, start: 16, end: 16),
    ]
    let interval = DateInterval(start: date(10), end: date(20))
    let matchingDevice = try await store.sessions(
      in: interval, deviceID: deviceID, including: recent)
    #expect(matchingDevice == [pending, saved, ongoing])
    let allDevices = try await store.sessions(in: interval, including: recent)
    #expect(allDevices == [pending, saved, otherDevice, ongoing])
    #expect(try await store.sessions(in: interval) == [saved])
  }

  @Test func oversizedRecentSessionsAreRejected() async throws {
    let store = ActivityStore(url: nil)
    let recent = Array(
      repeating: session(start: 0, end: 10), count: ActivityStore.maximumBatchSize + 1)
    let interval = DateInterval(start: date(0), end: date(10))
    await #expect(throws: ActivityStore.Failure.batchTooLarge) {
      try await store.sessions(in: interval, including: recent)
    }
  }

  @Test func dayExportUsesUTCStartAndFiltersByDevice() async throws {
    let store = ActivityStore(url: nil)
    let deviceID = UUID()
    let otherDeviceID = UUID()
    let crossesMidnight = session(deviceID: deviceID, start: -0.00025, end: 10)
    let startsAtMidnight = session(deviceID: deviceID, start: 0, end: 10)
    let sameDay = session(deviceID: deviceID, start: 12, end: 20)
    let otherDevice = session(deviceID: otherDeviceID, start: 0, end: 20)
    try await store.insert([otherDevice, sameDay, startsAtMidnight, crossesMidnight])

    #expect(Set(try await store.deviceIDs()) == [deviceID, otherDeviceID])
    #expect(try await store.localDays(deviceID: deviceID) == ["2000-12-31", "2001-01-01"])
    #expect(try await store.localDays(deviceID: otherDeviceID) == ["2001-01-01"])
    #expect(try await store.exportDay("2000-12-31", deviceID: deviceID) == [crossesMidnight])
    let currentDay = try await store.exportDay("2001-01-01", deviceID: deviceID)
    #expect(currentDay == [startsAtMidnight, sameDay])
    #expect(try await store.exportDay("2001-01-01", deviceID: otherDeviceID) == [otherDevice])
    #expect(try await store.exportDay("2001-01-02", deviceID: deviceID).isEmpty)
    await #expect(throws: ActivityStore.Failure.invalidDay) {
      try await store.exportDay("2001-02-29", deviceID: deviceID)
    }
  }

  @Test func invalidAndOversizedImportsLeaveTheStoreUnchanged() async throws {
    let store = ActivityStore(url: nil)
    let valid = session(start: 0, end: 10)
    let invalidSessions = [
      session(start: 10, end: 10),
      session(start: 0, end: .infinity),
      session(start: 0, end: 10, appName: String(repeating: "名", count: 400)),
      session(start: 0, end: 10, appName: "before\0after"),
      session(start: 0, end: 10, category: "unknown"),
    ]
    for invalid in invalidSessions {
      await #expect(throws: ActivityStore.Failure.invalidSession) {
        try await store.insert([valid, invalid])
      }
    }
    await #expect(throws: ActivityStore.Failure.batchTooLarge) {
      try await store.insert(Array(repeating: valid, count: ActivityStore.maximumBatchSize + 1))
    }
    #expect(try await store.deviceIDs().isEmpty)
  }

  private func session(
    id: UUID = UUID(), deviceID: UUID = UUID(), start: TimeInterval, end: TimeInterval,
    appName: String = "Editor", category: String = "work"
  ) -> ActivitySession {
    ActivitySession(
      id: id, deviceID: deviceID, appID: "com.example.editor", appName: appName,
      category: category, start: date(start), end: date(end))
  }

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
  }

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("activity.sqlite")
  }

  private func execute(_ sql: String, on url: URL) throws {
    var handle: OpaquePointer?
    let status = sqlite3_open(url.path, &handle)
    defer { sqlite3_close(handle) }
    guard status == SQLITE_OK, let handle else { throw FixtureFailure.sqlite(status) }
    let result = sqlite3_exec(handle, sql, nil, nil, nil)
    guard result == SQLITE_OK else { throw FixtureFailure.sqlite(result) }
  }
}
