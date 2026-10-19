// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

public struct AIAgentTool: Identifiable, Sendable {
  public enum Installation: Sendable { case installed, dataOnly, absent }
  public let id: String
  public let name: String
  public let installation: Installation
  public let executable: URL?
  public let dataDirectories: [URL]
  /// nil 表示未能完整计量，不把读取失败解释为零占用。
  public let bytes: UInt64?
}

public struct AICleanupScan: Sendable {
  public var tools: [AIAgentTool] = []
  public var worktrees: [AIWorktree] = []
  public var logs: [RuleScan] = []
  public var incomplete = false
  public var gitAvailable = true
  public var searchedRoots: [URL] = []
  public init() {}
  public var installedCount: Int { tools.filter { $0.installation == .installed }.count }
}

public struct AICleanupEnvironment: Sendable {
  public var home: String
  public var variables: [String: String]
  public var searchRoots: [URL]?
  public var executable: @Sendable (String) -> URL?
  public var hasGit: @Sendable () -> Bool
  public var codexDesktopInstalled: @Sendable () -> Bool
  public var clean: CleanEnvironment

  public init(
    home: String = NSHomeDirectory(),
    variables: [String: String] = ProcessInfo.processInfo.environment,
    searchRoots: [URL]? = nil, executable: (@Sendable (String) -> URL?)? = nil,
    hasGit: (@Sendable () -> Bool)? = nil,
    codexDesktopInstalled: (@Sendable () -> Bool)? = nil,
    clean: CleanEnvironment? = nil
  ) {
    self.home = home
    self.variables = variables
    self.searchRoots = searchRoots
    self.executable = executable ?? { DeveloperToolRunner.executable(named: $0, home: home) }
    self.hasGit = hasGit ?? { ProjectPurge.developerToolsInstalled() }
    self.codexDesktopInstalled =
      codexDesktopInstalled ?? {
        AIAgentCleanup.codexDesktopInstalled(home: URL(fileURLWithPath: home))
      }
    self.clean = clean ?? CleanEnvironment(home: home, runningBundleIdentifiers: { [] })
  }
}

public enum AIAgentCleanup {
  private struct Definition {
    let id: String
    let name: String
    let command: String
    let paths: [URL]
  }

  /// 单次扫描的遍历总量与时间均有上限；只在页面打开或手动刷新时调用。
  @concurrent
  public static func scan(environment: AICleanupEnvironment) async throws -> AICleanupScan {
    let budget = AIScanBudget()
    let home = URL(fileURLWithPath: environment.home).standardizedFileURL
    let codex = configured(
      "CODEX_HOME", fallback: home.appendingPathComponent(".codex"), environment)
    let claude = configured(
      "CLAUDE_CONFIG_DIR", fallback: home.appendingPathComponent(".claude"), environment)
    let data = configured(
      "XDG_DATA_HOME", fallback: home.appendingPathComponent(".local/share"), environment)
    let cache = configured(
      "XDG_CACHE_HOME", fallback: home.appendingPathComponent(".cache"), environment)
    let config = configured(
      "XDG_CONFIG_HOME", fallback: home.appendingPathComponent(".config"), environment)
    let definitions = [
      Definition(id: "codex", name: "Codex", command: "codex", paths: [codex]),
      Definition(id: "claude", name: "Claude Code", command: "claude", paths: [claude]),
      Definition(
        id: "gemini", name: "Gemini CLI", command: "gemini",
        paths: [home.appendingPathComponent(".gemini")]),
      Definition(
        id: "opencode", name: "OpenCode", command: "opencode",
        paths: [
          data.appendingPathComponent("opencode"), cache.appendingPathComponent("opencode"),
          config.appendingPathComponent("opencode"),
        ]),
      Definition(
        id: "cursor", name: "Cursor Agent", command: "cursor-agent",
        paths: [home.appendingPathComponent(".cursor")]),
      Definition(
        id: "aider", name: "Aider", command: "aider", paths: [home.appendingPathComponent(".aider")]
      ),
    ]
    var result = AICleanupScan()
    var measured = Set<String>()
    for definition in definitions {
      try Task.checkCancellation()
      let executable = environment.executable(definition.command)
      let paths = definition.paths.filter { FileManager.default.fileExists(atPath: $0.path) }
      var total: UInt64 = 0
      var complete = true
      for path in paths {
        // 自定义数据位置与其他工具重叠时，不重复计量，也不宣称完整占用。
        let normalized = path.standardizedFileURL.path
        guard
          !measured.contains(where: {
            normalized == $0 || normalized.hasPrefix($0 + "/") || $0.hasPrefix(normalized + "/")
          })
        else {
          complete = false
          result.incomplete = true
          continue
        }
        measured.insert(normalized)
        do {
          total += try AIScanBudget(
            seconds: 2, entries: 10_000, deadline: budget.deadline, parent: budget
          ).size(
            path, excludingWorktrees: true)
        } catch is CancellationError { throw CancellationError() } catch {
          complete = false
          result.incomplete = true
        }
      }
      result.tools.append(
        AIAgentTool(
          id: definition.id, name: definition.name,
          installation: executable != nil
            || (definition.id == "codex" && environment.codexDesktopInstalled())
            ? .installed : paths.isEmpty ? .absent : .dataOnly,
          executable: executable, dataDirectories: paths, bytes: complete ? total : nil))
    }
    let managed = [
      codex.appendingPathComponent("worktrees"), claude.appendingPathComponent("worktrees"),
    ]
    let defaults = [
      "Work", "go/src", "Projects", "GitHub", "Code", "Workspace", "Repos", "Development", "dev",
      "www",
    ]
    .map { home.appendingPathComponent($0) }
    let roots = (environment.searchRoots ?? defaults) + managed
    result.searchedRoots = Array(Set(roots.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    result.gitAvailable = environment.hasGit()
    if result.gitAvailable {
      let discovered = try AIWorktrees.discover(
        roots: result.searchedRoots, home: environment.home,
        excludedPaths: environment.clean.excludedPaths, budget: budget)
      result.worktrees = discovered.items
      result.incomplete = result.incomplete || discovered.incomplete
    }
    try Task.checkCancellation()
    result.logs = await CleanEngine.scan(
      logRules(environment: environment), environment: environment.clean)
    result.incomplete =
      result.incomplete || result.logs.contains { $0.unreadableCount > 0 || $0.blocked != nil }
    try Task.checkCancellation()
    return result
  }

  /// 仅登记默认位置的旧普通日志文件，不清理自定义路径、会话、SQLite、配置或快照。
  public static func logRules(environment: AICleanupEnvironment) -> [CleanRule] {
    let paths = [
      ("codex", ".codex/log", "CODEX_HOME", environment.home + "/.codex"),
      ("claude", ".claude/debug", "CLAUDE_CONFIG_DIR", environment.home + "/.claude"),
      (
        "opencode", ".local/share/opencode/log", "XDG_DATA_HOME", environment.home + "/.local/share"
      ),
    ]
    return paths.compactMap { id, relative, variable, defaultRoot in
      if let custom = environment.variables[variable],
        URL(fileURLWithPath: custom).standardizedFileURL.path != defaultRoot
      {
        return nil
      }
      return CleanRule(
        id: "ai.logs." + id, category: .developer, title: id,
        detail: tr("仅清理 7 天前的日志，保留会话、配置与凭据"), symbol: "doc.text",
        selectedByDefault: false, policy: .trash, requiresUnredirectedPath: true,
        minimumAge: 7 * 86_400
      ) { env in
        let root = URL(fileURLWithPath: env.home).appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var unreadable = false
        guard AppUninstaller.isUnredirected(root, home: env.home),
          let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
              unreadable = true
              return false
            })
        else { throw CocoaError(.fileReadNoPermission) }
        var files: [URL] = []
        var visited = 0
        for case let file as URL in entries {
          try Task.checkCancellation()
          visited += 1
          guard visited <= 2_000 else { throw AIScanError.limit }
          let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          if values.isRegularFile == true, values.isSymbolicLink != true,
            ["log", "txt"].contains(file.pathExtension.lowercased())
          {
            files.append(file)
          }
        }
        if unreadable { throw CocoaError(.fileReadNoPermission) }
        return files
      }
    }
  }

  static func codexDesktopInstalled(home: URL) -> Bool {
    [
      URL(fileURLWithPath: "/Applications/Codex.app"),
      home.appendingPathComponent("Applications/Codex.app"),
    ].contains { url in
      guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.openai.codex",
        let executable = bundle.executableURL
      else { return false }
      return FileManager.default.isExecutableFile(atPath: executable.path)
    }
  }

  private static func configured(_ key: String, fallback: URL, _ environment: AICleanupEnvironment)
    -> URL
  {
    guard let value = environment.variables[key], value.hasPrefix("/"), !value.isEmpty else {
      return fallback
    }
    return URL(fileURLWithPath: value).standardizedFileURL
  }
}

enum AIScanError: Error { case limit }

/// 每个扫描任务独享，不跨任务共享可变计数。达到预算后保留已发现项，并明确标为不完整。
final class AIScanBudget {
  let deadline: Date
  private var remaining: Int
  private let parent: AIScanBudget?
  init(
    seconds: TimeInterval = 25, entries: Int = 60_000, deadline: Date = .distantFuture,
    parent: AIScanBudget? = nil
  ) {
    self.deadline = min(deadline, Date().addingTimeInterval(seconds))
    remaining = entries
    self.parent = parent
  }
  func check() throws {
    try Task.checkCancellation()
    try parent?.check()
    remaining -= 1
    guard remaining >= 0, Date() < deadline else { throw AIScanError.limit }
  }
  func size(_ root: URL, excludingWorktrees: Bool = false) throws -> UInt64 {
    try check()
    guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else {
      throw AIScanError.limit
    }
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .fileAllocatedSizeKey]
    var failed = false
    guard
      let entries = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: Array(keys), options: [],
        errorHandler: { _, _ in
          failed = true
          return false
        })
    else { throw AIScanError.limit }
    var bytes: UInt64 = 0
    for case let entry as URL in entries {
      try check()
      let values = try entry.resourceValues(forKeys: keys)
      if values.isSymbolicLink == true
        || (excludingWorktrees
          && entry.standardizedFileURL.path
            == root.appendingPathComponent("worktrees").standardizedFileURL.path)
      {
        entries.skipDescendants()
        continue
      }
      if values.isRegularFile == true { bytes += UInt64(values.fileAllocatedSize ?? 0) }
    }
    if failed { throw AIScanError.limit }
    return bytes
  }
}
