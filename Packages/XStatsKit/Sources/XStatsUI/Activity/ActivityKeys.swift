// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Security

enum ActivityKeys {
  enum Failure: Error {
    case unavailable, invalidRecoveryCode, replacementRequired
  }

  static func localKey(createIfMissing: Bool) throws -> SymmetricKey {
    try key(account: "database", createIfMissing: createIfMissing)
  }

  static func syncKey() throws -> SymmetricKey {
    try key(account: "sync", createIfMissing: true)
  }

  static func preferencesKey(createIfMissing: Bool) throws -> SymmetricKey {
    try key(account: "settings-state", createIfMissing: createIfMissing)
  }

  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "work.12306.xstats.activity.keys",
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  fileprivate static func existingKey(account: String) throws -> SymmetricKey? {
    var lookup = query(account)
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecSuccess {
      guard let bytes = result as? Data, bytes.count == 32 else { throw Failure.unavailable }
      return SymmetricKey(data: bytes)
    }
    guard status == errSecItemNotFound else { throw Failure.unavailable }
    return nil
  }

  private static func key(account: String, createIfMissing: Bool) throws -> SymmetricKey {
    if let existing = try existingKey(account: account) { return existing }
    guard createIfMissing else { throw Failure.unavailable }
    let candidate = SymmetricKey(size: .bits256)
    let inserted = add(candidate, account: account)
    if inserted == errSecDuplicateItem { return try key(account: account, createIfMissing: false) }
    guard inserted == errSecSuccess else { throw Failure.unavailable }
    return candidate
  }

  static func replaceSyncKey(_ imported: SymmetricKey) throws {
    let attributes = [kSecValueData as String: imported.withUnsafeBytes { Data($0) }]
    let status = SecItemUpdate(query("sync") as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      guard add(imported, account: "sync") == errSecSuccess else { throw Failure.unavailable }
    } else if status != errSecSuccess {
      throw Failure.unavailable
    }
  }

  private static func add(_ key: SymmetricKey, account: String) -> OSStatus {
    var item = query(account)
    item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    item[kSecAttrLabel as String] = "XStats App Activity (\(account))"
    return SecItemAdd(item as CFDictionary, nil)
  }

  static func recoveryCode(for key: SymmetricKey) -> String {
    let data = key.withUnsafeBytes { Data($0) }
    let checked = data + SHA256.hash(data: data).prefix(4)
    return "XSA1-"
      + checked.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
  }

  static func decode(_ input: String) throws -> SymmetricKey {
    guard input.utf8.prefix(257).count <= 256 else { throw Failure.invalidRecoveryCode }
    let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard code.utf8.count == 53, code.hasPrefix("XSA1-") else { throw Failure.invalidRecoveryCode }
    let encoded = code.dropFirst(5).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    guard let checked = Data(base64Encoded: encoded), checked.count == 36 else {
      throw Failure.invalidRecoveryCode
    }
    let key = SymmetricKey(data: checked.prefix(32))
    guard recoveryCode(for: key) == code else { throw Failure.invalidRecoveryCode }
    return key
  }
}

actor ActivitySyncKeys {
  private let persistent: Bool
  private var current: SymmetricKey?

  init(persistent: Bool) { self.persistent = persistent }

  func key() throws -> SymmetricKey {
    if let current { return current }
    let loaded = persistent ? try ActivityKeys.syncKey() : SymmetricKey(size: .bits256)
    current = loaded
    return loaded
  }

  func replace(with code: String, confirmExisting: Bool) throws {
    let imported = try ActivityKeys.decode(code)
    let existing = persistent ? try ActivityKeys.existingKey(account: "sync") : current
    if let existing, existing != imported, !confirmExisting {
      throw ActivityKeys.Failure.replacementRequired
    }
    if persistent { try ActivityKeys.replaceSyncKey(imported) }
    current = imported
  }
}

struct ActivitySharedKeys: Sendable {
  let read: @Sendable (String) throws -> SymmetricKey?
  let insert: @Sendable (String, SymmetricKey) throws -> SymmetricKey

  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "work.12306.xstats.activity.shared-keys",
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: true,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  private static func lookup(_ account: String) throws -> SymmetricKey? {
    var query = query(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
      throw ActivityKeys.Failure.unavailable
    }
    return SymmetricKey(data: data)
  }

  static let keychain = Self(
    read: lookup,
    insert: { account, key in
      var item = query(account)
      item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
      let status = SecItemAdd(item as CFDictionary, nil)
      if status == errSecSuccess { return key }
      guard status == errSecDuplicateItem, let winner = try lookup(account) else {
        throw ActivityKeys.Failure.unavailable
      }
      return winner
    })

  static var available: Self? {
    guard let task = SecTaskCreateFromSelf(nil),
      let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
        as? [String], groups.contains(where: { $0.hasSuffix(".work.12306.xstats.app") })
    else { return nil }
    return .keychain
  }
}
