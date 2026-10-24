// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 一次扫描中的应用证据，仅保存清理清单的规则 ID，不常驻完整应用列表或启动后台轮询。
public struct CacheApplicationInventory: Sendable {
  public let installedRuleIDs: Set<String>
  public let isComplete: Bool

  public init(
    rules: [CleanRule], applications: [InstalledApp], isComplete: Bool,
    runningIdentifiers: Set<String> = [], runningNames: Set<String> = []
  ) {
    let identifiers = Set(applications.map(\.bundleIdentifier)).union(runningIdentifiers)
    let names = Set(
      applications.flatMap { [$0.name, $0.url.deletingPathExtension().lastPathComponent] }
    ).union(runningNames)
    installedRuleIDs = Set(
      rules.filter {
        $0.tracksApplicationPresence
          && $0.runningApplication(identifiers: identifiers, names: names) != nil
      }.map(\.id))
    self.isComplete = isComplete
  }

  /// 结构化子任务离开主线程读取元数据；父任务取消会传入应用目录遍历。
  public static func read(rules: [CleanRule], environment: CleanEnvironment) async throws -> Self {
    try await withThrowingTaskGroup(of: Self.self) { group in
      group.addTask {
        try AppUninstaller.cacheApplicationInventory(rules: rules, environment: environment)
      }
      return try await group.next()!
    }
  }
}
