// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import os

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
  public var applicationDirectories: [URL]
  public var clean: CleanEnvironment

  public init(
    home: String = NSHomeDirectory(),
    variables: [String: String] = ProcessInfo.processInfo.environment,
    searchRoots: [URL]? = nil, executable: (@Sendable (String) -> URL?)? = nil,
    hasGit: (@Sendable () -> Bool)? = nil,
    codexDesktopInstalled: (@Sendable () -> Bool)? = nil,
    applicationDirectories: [URL]? = nil,
    clean: CleanEnvironment? = nil
  ) {
    self.home = home
    self.variables = variables
    self.searchRoots = searchRoots
    self.applicationDirectories =
      applicationDirectories ?? [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: home).appendingPathComponent("Applications"),
      ]
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
  private static let logger = Logger(subsystem: "work.12306.xstats", category: "ai-cleanup")

  private struct Definition {
    let id: String
    let name: String
    let command: String?
    let paths: [URL]
    var bundles: [String] = []
  }

  /// 单次扫描的遍历总量与时间均有上限；只在页面打开或手动刷新时调用。
  @concurrent
  public static func scan(environment: AICleanupEnvironment) async throws -> AICleanupScan {
    let budget = AIScanBudget()
    // 工具数量增长后不能耗尽 Worktree 的条目预算；统计最多占用前 10 秒，
    // 两阶段各有有界条目预算，仍共用整次扫描的 25 秒截止时间。
    let toolBudget = AIScanBudget(seconds: 10, deadline: budget.deadline)
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
    let support = home.appendingPathComponent("Library/Application Support")
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
      // VS Code 的共享配置、扩展与工作区存储不能整体归入 Agent 数据。
      Definition(
        id: "vscode", name: "VS Code (Copilot)", command: "code",
        paths: ["Code", "Code - Insiders"].flatMap { edition in
          ["github.copilot-chat", "emptyWindowChatSessions"].map {
            support.appendingPathComponent("\(edition)/User/globalStorage/\($0)")
          }
        }, bundles: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
      Definition(
        id: "grok", name: "Grok Build", command: "grok",
        paths: [
          configured("GROK_HOME", fallback: home.appendingPathComponent(".grok"), environment)
        ]),
      Definition(
        id: "claude-desktop", name: "Claude Desktop", command: nil,
        paths: [support.appendingPathComponent("Claude")],
        bundles: ["com.anthropic.claudefordesktop"]),
      Definition(
        id: "deepseek", name: "DeepSeek Harness", command: "dsh",
        paths: [
          configured("DSH_HOME", fallback: home.appendingPathComponent(".dsh"), environment),
          support.appendingPathComponent("@deepseek-ai/dsh-desktop"),
        ], bundles: ["com.deepseek.dsh"]),
      Definition(
        id: "pi", name: "Pi", command: "pi",
        paths: [
          configured(
            "PI_CODING_AGENT_DIR", fallback: home.appendingPathComponent(".pi/agent"), environment)
        ]),
      Definition(
        id: "cindy", name: "Cindy", command: nil,
        paths: [home.appendingPathComponent(".cindy")]
          + ["Cindy", "CindyGlobal"].map { support.appendingPathComponent($0) },
        bundles: ["com.xd.cindy", "com.xd.cindycn"]),
      Definition(
        id: "codebuddy", name: "CodeBuddy", command: "codebuddy",
        paths: [".codebuddy", ".codebuddycn"].map { home.appendingPathComponent($0) }
          + ["CodeBuddy", "CodeBuddy CN", "CodeBuddyExtension"].map {
            support.appendingPathComponent($0)
          }, bundles: ["com.tencent.codebuddy", "com.tencent.codebuddycn"]),
      Definition(
        id: "workbuddy", name: "WorkBuddy", command: nil,
        paths: [home.appendingPathComponent(".workbuddy")]
          + ["WorkBuddy", "com.tencent.workbuddy.mac", "com.workbuddy.workbuddy"].map {
            support.appendingPathComponent($0)
          },
        bundles: ["com.tencent.workbuddy.mac", "com.workbuddy.workbuddy"]),
    ]
    let desktopDetection = try desktopBundleIdentifiers(
      in: environment.applicationDirectories,
      budget: AIScanBudget(seconds: 2, entries: 1_000, parent: toolBudget))
    var result = AICleanupScan()
    result.incomplete = desktopDetection.incomplete
    var measured = Set<String>()
    for definition in definitions {
      try Task.checkCancellation()
      let executable = definition.command.flatMap { environment.executable($0) }
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
        let started = Date()
        do {
          // Codex 的临时文件与插件可能超过一万项；扩大条目预算，但仍受单目录时限与全局预算约束。
          total += try AIScanBudget(
            seconds: 2, entries: 30_000, deadline: toolBudget.deadline, parent: toolBudget
          ).size(
            path, excludingWorktrees: definition.id == "codex" || definition.id == "claude")
        } catch is CancellationError { throw CancellationError() } catch {
          let failure = error as NSError
          logger.warning(
            "Tool data measurement incomplete: tool=\(definition.id, privacy: .public) elapsed=\(Date().timeIntervalSince(started), privacy: .public) error=\(failure.domain, privacy: .public):\(failure.code, privacy: .public) detail=\(String(failure.localizedDescription.prefix(256)), privacy: .private)"
          )
          complete = false
          result.incomplete = true
        }
      }
      result.tools.append(
        AIAgentTool(
          id: definition.id, name: definition.name,
          installation: executable != nil
            || definition.bundles.contains(where: desktopDetection.identifiers.contains)
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

  /// 只检查两个标准应用目录的直接子项；不启动应用，不进行 Spotlight 或全盘搜索。
  static func desktopBundleIdentifiers(in directories: [URL], budget: AIScanBudget) throws
    -> (identifiers: Set<String>, incomplete: Bool)
  {
    var identifiers = Set<String>()
    var incomplete = false
    do {
      for directory in directories {
        try budget.check()
        guard FileManager.default.fileExists(atPath: directory.path) else { continue }
        // 惰性读取直接子项，并与工具阶段共享预算，为 Worktree 发现保留时间。
        guard
          let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants],
            errorHandler: { _, _ in
              incomplete = true
              return false
            })
        else { throw AIScanError.limit }
        for case let url as URL in entries {
          try budget.check()
          guard url.pathExtension == "app",
            let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
            let executable = bundle.executableURL,
            FileManager.default.isExecutableFile(atPath: executable.path)
          else { continue }
          identifiers.insert(identifier)
        }
      }
    } catch is CancellationError { throw CancellationError() } catch {
      incomplete = true
    }
    return (identifiers, incomplete)
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
    let root = root.standardizedFileURL
    guard root.path == root.resolvingSymlinksInPath().path else {
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
    // 排除路径只计算一次；仅同名条目需要规范化，以兼容 /var 与 /private/var 等系统路径别名。
    let worktreesPath =
      excludingWorktrees
      ? root.appendingPathComponent("worktrees", isDirectory: true).path : nil
    var bytes: UInt64 = 0
    for case let entry as URL in entries {
      try check()
      let values = try entry.resourceValues(forKeys: keys)
      if values.isSymbolicLink == true
        || (excludingWorktrees && entry.lastPathComponent == "worktrees"
          && entry.standardizedFileURL.path == worktreesPath)
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
