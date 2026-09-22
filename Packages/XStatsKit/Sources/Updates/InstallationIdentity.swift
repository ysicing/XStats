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
    case random(OSStatus)

    var errorDescription: String? {
        switch self {
        case .random(let status):
            "Random generator error \(status)"
        }
    }
}

/// 首次使用时生成随机值并留存在本机偏好设置；它不是凭据，不能因读取而触发钥匙串授权。
public struct InstallationIdentity {
    private let store: any InstallationIDStore
    private let randomBytes: () throws -> Data

    public init() {
        self.store = UserDefaultsInstallationIDStore(defaults: .standard)
        self.randomBytes = Self.generateRandomBytes
    }

    init(defaults: UserDefaults, randomBytes: @escaping () throws -> Data) {
        self.store = UserDefaultsInstallationIDStore(defaults: defaults)
        self.randomBytes = randomBytes
    }

    init(store: any InstallationIDStore, randomBytes: @escaping () throws -> Data) {
        self.store = store
        self.randomBytes = randomBytes
    }

    /// 返回可上报的稳定哈希；随机原值只保存在本机且不随设置同步。
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

struct UserDefaultsInstallationIDStore: InstallationIDStore {
    static let key = "installationIdentitySeed"
    let defaults: UserDefaults

    func read() throws -> Data? { defaults.data(forKey: Self.key) }

    func write(_ value: Data) throws { defaults.set(value, forKey: Self.key) }
}
