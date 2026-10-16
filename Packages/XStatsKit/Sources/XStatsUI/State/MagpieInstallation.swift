// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import AppKit
import Foundation

@MainActor
enum MagpieInstallation {
  /// 启动时检测应用，不启动 Magpie，不读取账户或凭据文件。卸载/安装后重启 XStats 重新选择来源。
  static func client() -> MagpieClient? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let installed =
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.yetone.magpie").flatMap {
        Bundle(url: $0)
      }?.bundleIdentifier == "com.yetone.magpie"
      || [
        URL(fileURLWithPath: "/Applications/magpie.app"),
        home.appendingPathComponent("Applications/magpie.app"),
      ]
      .contains { Bundle(url: $0)?.bundleIdentifier == "com.yetone.magpie" }
    let cliInstalled = [
      "/opt/homebrew/bin/magpie", "/usr/local/bin/magpie",
      home.appendingPathComponent(".local/bin/magpie").path,
    ]
    .contains { FileManager.default.isExecutableFile(atPath: $0) }
    guard installed || cliInstalled else { return nil }
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
    return try? MagpieClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
  }
}
