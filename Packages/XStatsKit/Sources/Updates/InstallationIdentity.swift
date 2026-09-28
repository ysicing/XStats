// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import IOKit
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

/// 旧安装沿用本机偏好中的随机值；新安装按机器序列号去重，均只上报哈希。
public struct InstallationIdentity {
    private let store: any InstallationIDStore
    private let serialNumber: () -> String?
    private let randomBytes: () throws -> Data

    public init() {
        self.store = UserDefaultsInstallationIDStore(defaults: .standard)
        self.serialNumber = Self.readSerialNumber
        self.randomBytes = Self.generateRandomBytes
    }

    init(defaults: UserDefaults, serialNumber: @escaping () -> String?, randomBytes: @escaping () throws -> Data) {
        self.store = UserDefaultsInstallationIDStore(defaults: defaults)
        self.serialNumber = serialNumber
        self.randomBytes = randomBytes
    }

    init(store: any InstallationIDStore, serialNumber: @escaping () -> String?, randomBytes: @escaping () throws -> Data) {
        self.store = store
        self.serialNumber = serialNumber
        self.randomBytes = randomBytes
    }

    /// 优先保留旧标识；新安装使用序列号，无法读取时才生成本机随机值。
    public func hashedID() throws -> String {
        let value: Data
        if let saved = try store.read() {
            value = saved
        } else if let serial = serialNumber()?.trimmingCharacters(in: .whitespacesAndNewlines), !serial.isEmpty {
            value = Data(serial.utf8)
        } else {
            value = try randomBytes()
            try store.write(value)
        }
        return SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    private static func readSerialNumber() -> String? {
        let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platform != 0 else { return nil }
        defer { IOObjectRelease(platform) }
        return IORegistryEntryCreateCFProperty(platform, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
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
