// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum ThumbnailCache {
  /// 只重置当前用户的缩略图缓存，不删除文件、重启 Finder 或请求管理员权限。
  public static func reset() async throws {
    try await reset { arguments in
      try await DeveloperToolRunner.run(
        "qlmanage", arguments: arguments, home: NSHomeDirectory(),
        timeout: 30, outputLimit: 4096,
        executableURL: URL(fileURLWithPath: "/usr/bin/qlmanage"))
    }
  }

  static func reset(
    run: @Sendable ([String]) async throws -> ToolRunResult
  ) async throws {
    try Task.checkCancellation()
    let result = try await run(["-r", "cache"])
    try Task.checkCancellation()
    guard result.status == 0 else {
      throw ToolExecutionError.failed(
        tool: "qlmanage", status: result.status, output: result.output)
    }
  }
}
