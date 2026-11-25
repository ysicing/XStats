// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import os
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

  @MainActor @Test func confirmedImportReplacesTheSharedDefaultKey() async throws {
    let suite = "ActivitySharedKeyImportTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldKey = SymmetricKey(size: .bits256)
    let newKey = SymmetricKey(size: .bits256)
    let shared = OSAllocatedUnfairLock(initialState: oldKey)
    let keychain = ActivitySharedKeys(
      read: { _ in shared.withLock { $0 } },
      insert: { _, _ in shared.withLock { $0 } },
      replace: { account, key in
        #expect(account == "default")
        shared.withLock { $0 = key }
      })
    let controller = ActivitySyncController(
      store: ActivityStore(url: nil), deviceID: UUID(), defaults: defaults, sharedKeys: keychain)
    let code = ActivityKeys.recoveryCode(for: newKey)

    await #expect(throws: ActivityKeys.Failure.replacementRequired) {
      try await controller.importRecoveryCode(code)
    }
    #expect(shared.withLock { $0 } == oldKey)
    try await controller.importRecoveryCode(code, confirmExisting: true)
    #expect(shared.withLock { $0 } == newKey)
    #expect(try await controller.recoveryCode() == code)
  }

  @MainActor @Test func sharedKeychainWriteFailureKeepsTheImportedLocalKey() async throws {
    let suite = "ActivitySharedKeyImportFailureTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldKey = SymmetricKey(size: .bits256)
    let newKey = SymmetricKey(size: .bits256)
    let keychain = ActivitySharedKeys(
      read: { _ in oldKey },
      insert: { _, _ in oldKey },
      replace: { account, key in
        #expect(account == "default")
        #expect(key == newKey)
        throw ActivityKeys.Failure.unavailable
      })
    let controller = ActivitySyncController(
      store: ActivityStore(url: nil), deviceID: UUID(), defaults: defaults, sharedKeys: keychain)
    let originalCode = try await controller.recoveryCode()
    let code = ActivityKeys.recoveryCode(for: newKey)
    #expect(originalCode != code)

    await #expect(throws: ActivityKeys.Failure.sharedKeyUnavailable) {
      try await controller.importRecoveryCode(code, confirmExisting: true)
    }
    let localCode = try await controller.recoveryCode()
    #expect(localCode == code)
    let fingerprint = newKey.withUnsafeBytes { ActivitySyncShard.checksum(Data($0)) }
    #expect(defaults.string(forKey: "activity.sync.importedKeyFingerprint") == fingerprint)
    #expect(!controller.changingKey)
  }
}
