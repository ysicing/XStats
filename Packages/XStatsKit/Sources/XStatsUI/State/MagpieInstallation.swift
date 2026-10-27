// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Foundation

@MainActor
enum MagpieInstallation {
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
}
