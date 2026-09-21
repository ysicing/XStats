// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Security

protocol InstallationIDStore {
    func read() throws -> Data?
    func write(_ value: Data) throws
}

enum InstallationIdentityError: Error, LocalizedError {
    case keychain(OSStatus)
    case random(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        case .random(let status):
            "Random generator error \(status)"
        }
    }
}

/// 每次安装首次使用时生成随机值并留存在本机钥匙串；网络侧只使用它的 SHA-256。
public struct InstallationIdentity {
    private let store: any InstallationIDStore
    private let randomBytes: () throws -> Data

    public init() {
        self.store = KeychainInstallationIDStore()
        self.randomBytes = Self.generateRandomBytes
    }

    init(store: any InstallationIDStore, randomBytes: @escaping () throws -> Data) {
        self.store = store
        self.randomBytes = randomBytes
    }

    /// 返回可上报的稳定哈希；随机原值永不离开钥匙串。
    public func hashedID() throws -> String {
        let value: Data
        if let saved = try store.read() {
            value = saved
        } else {
            value = try randomBytes()
            try store.write(value)
        }
        return SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    private static func generateRandomBytes() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw InstallationIdentityError.random(status) }
        return data
    }
}

struct KeychainInstallationIDStore: InstallationIDStore {
    private static let service = "work.12306.xstats.installation"
    private static let account = "installation-id"

    init() {}

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw InstallationIdentityError.keychain(status == errSecSuccess ? errSecDecode : status)
        }
        return data
    }

    func write(_ value: Data) throws {
        let query = baseQuery
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw InstallationIdentityError.keychain(status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}
