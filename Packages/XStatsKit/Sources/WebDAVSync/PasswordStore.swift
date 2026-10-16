// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
//
// Upstream portions retain their MIT license.
// XStats modifications are licensed under AGPL-3.0-or-later.
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Security

/// 连接密码仅存本机钥匙串，读写失败必须明确报告，不能伪装成空密码。
@MainActor
public protocol WebDAVPasswordStore {
    func read(account: String) throws -> String?
    func write(_ password: String, account: String) throws
}

/// 使用文件式钥匙串，兼容本机 ad-hoc 签名；各服务器与用户独立存储。
@MainActor
public struct KeychainWebDAVPasswordStore: WebDAVPasswordStore {
    public init() {}
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "work.12306.xstats.webdav",
         kSecAttrAccount as String: account]
    }

    public func read(account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw WebDAVKeychainError(status: status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw WebDAVKeychainError(status: errSecDecode)
        }
        return password
    }

    public func write(_ password: String, account: String) throws {
        let query = query(account)
        let data = Data(password.utf8)
        // 显式限定为本机、解锁后可读，避免被误加同步属性导致密码随 iCloud 钥匙串同步。
        let attributes: [String: Any] = [kSecValueData as String: data,
                                          kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "XStats WebDAV"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WebDAVKeychainError(status: status) }
    }
}

public struct WebDAVKeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
