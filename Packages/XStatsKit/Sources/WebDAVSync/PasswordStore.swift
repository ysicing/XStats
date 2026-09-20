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
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "XStats WebDAV"
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
