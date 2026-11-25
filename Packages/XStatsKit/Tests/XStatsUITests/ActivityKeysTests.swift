// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import XStatsUI

struct ActivityKeysTests {
  @Test func recoveryCodeChecksVersionLengthAndChecksum() throws {
    let key = SymmetricKey(size: .bits256)
    let code = ActivityKeys.recoveryCode(for: key)
    let imported = try ActivityKeys.decode("\n\(code)\n")
    #expect(imported == key)
    let replacement = code.last == "A" ? "B" : "A"
    for invalid in [
      String(code.dropLast()), String(code.dropLast()) + replacement,
      "XSA0-" + code.dropFirst(5), String(repeating: "A", count: 500),
    ] {
      #expect(throws: ActivityKeys.Failure.self) { try ActivityKeys.decode(invalid) }
    }
  }

  @MainActor @Test func importingAnotherMacsRecoveryCodePreservesLocalHistory() async throws {
    let firstSuite = "ActivityKeysTests.\(UUID())"
    let secondSuite = "ActivityKeysTests.\(UUID())"
    let firstDefaults = try #require(UserDefaults(suiteName: firstSuite))
    let secondDefaults = try #require(UserDefaults(suiteName: secondSuite))
    defer {
      firstDefaults.removePersistentDomain(forName: firstSuite)
      secondDefaults.removePersistentDomain(forName: secondSuite)
    }
    let first = ActivityController(defaults: firstDefaults, databaseURL: nil)
    let second = ActivityController(defaults: secondDefaults, databaseURL: nil)
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let session = ActivitySession(
      id: UUID(), deviceID: second.deviceID, appID: "test.editor", appName: "Editor",
      category: "work", start: start, end: start + 90)
    try await second.store.insert([session])
    let originalCode = try await second.sync.recoveryCode()
    let importedCode = try await first.sync.recoveryCode()
    #expect(originalCode != importedCode)
    await #expect(throws: ActivityKeys.Failure.replacementRequired) {
      try await second.sync.importRecoveryCode(importedCode)
    }
    #expect(try await second.sync.recoveryCode() == originalCode)
    try await second.sync.importRecoveryCode(importedCode, confirmExisting: true)
    try await second.sync.importRecoveryCode(importedCode)
    #expect(try await second.sync.recoveryCode() == importedCode)
    await #expect(throws: ActivityKeys.Failure.self) {
      try await second.sync.importRecoveryCode("invalid")
    }
    #expect(try await second.sync.recoveryCode() == importedCode)
    #expect(
      try await second.store.sessions(in: DateInterval(start: start, duration: 90)) == [session])
    let saved = secondDefaults.persistentDomain(forName: secondSuite) ?? [:]
    #expect(!saved.values.contains { ($0 as? String) == importedCode })
  }

  @Test func firstImportRequiresNoReplacementConfirmation() async throws {
    let keys = ActivitySyncKeys(persistent: false)
    let shared = SymmetricKey(size: .bits256)
    try await keys.replace(with: ActivityKeys.recoveryCode(for: shared), confirmExisting: false)
    #expect(try await keys.key() == shared)
  }
}
