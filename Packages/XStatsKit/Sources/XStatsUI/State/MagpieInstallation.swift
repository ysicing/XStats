// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import AppKit
import Foundation
import Security

@MainActor
enum MagpieInstallation {
  enum Guidance: Equatable {
    case install
    case launch(URL)
    case retry

    static func resolve(application: URL?, commandLineInstalled: Bool, previouslyConnected: Bool)
      -> Self
    {
      if let application { return .launch(application) }
      return commandLineInstalled || previouslyConnected ? .retry : .install
    }
  }

  static func guidance(previouslyConnected: Bool) -> Guidance {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.yetone.magpie"),
      URL(fileURLWithPath: "/Applications/magpie.app"),
      home.appendingPathComponent("Applications/magpie.app"),
    ].compactMap { $0 }
    let application = candidates.first {
      Bundle(url: $0)?.bundleIdentifier == "com.yetone.magpie"
    }
    let commandLineInstalled = [
      "/opt/homebrew/bin/magpie", "/usr/local/bin/magpie",
      home.appendingPathComponent(".local/bin/magpie").path,
    ].contains { FileManager.default.isExecutableFile(atPath: $0) }
    return .resolve(
      application: application, commandLineInstalled: commandLineInstalled,
      previouslyConnected: previouslyConnected)
  }

  /// 只读取本地网关端口，不启动 Magpie 或读取账户凭据。
  static func client() -> MagpieClient {
    let home = FileManager.default.homeDirectoryForCurrentUser
    // 仅解码公开的网关端口；设置文件包含其他私密配置，不保存或打印其内容。
    struct GatewaySettings: Decodable { let port: Int? }
    let url = home.appendingPathComponent(".config/magpie/settings.json")
    var port = 3425
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
      let data = try? Data(contentsOf: url),
      let settings = try? JSONDecoder().decode(GatewaySettings.self, from: data),
      let configured = settings.port, (1024...65535).contains(configured)
    {
      port = configured
    }
    return try! MagpieClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
  }

  enum GatewayKeyError: Error {
    case keychain, missingKey
  }

  private static func keyQuery(_ endpoint: URL) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "work.12306.xstats.magpie",
      kSecAttrAccount as String: endpoint.absoluteString,
    ]
  }

  static func gatewayKey(for endpoint: URL) throws -> String {
    var query = keyQuery(endpoint)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { throw GatewayKeyError.missingKey }
    guard status == errSecSuccess, let data = result as? Data,
      let key = String(data: data, encoding: .utf8), !key.isEmpty
    else { throw GatewayKeyError.keychain }
    return key
  }

  static func saveGatewayKey(_ key: String, for endpoint: URL) throws {
    var query = keyQuery(endpoint)
    let data = Data(key.utf8)
    var status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      query[kSecValueData as String] = data
      query[kSecAttrLabel as String] = "XStats Magpie"
      query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      status = SecItemAdd(query as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw GatewayKeyError.keychain }
  }
}
