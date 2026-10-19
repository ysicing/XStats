// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Localization
import os

public struct AIWorktree: Identifiable, Sendable {
  public enum Protection: String, Sendable, Error {
    case changed, locked, detached, unavailable, outsideHome, submodule, excluded
    public var title: String {
      switch self {
      case .excluded: tr("已排除")
      case .changed: tr("有修改或未跟踪、被忽略的文件")
      case .locked: tr("worktree 已锁定")
      case .detached: tr("独立提交尚无分支或标签保留")
      case .unavailable: tr("无法完成安全检查")
      case .outsideHome: tr("路径不在家目录内或包含符号链接")
      case .submodule: tr("包含子模块，需在 Git 中处理")
      }
    }
  }
  public var id: String { url.path }
  public let url: URL
  public let repository: URL
  public let branch: String?
  public let head: String
  public let bytes: UInt64?
  public let protection: Protection?
  let identity: AIFileIdentity?
  let gitIdentity: AIFileIdentity?
  let commonIdentity: AIFileIdentity?
  public var canRemove: Bool { protection == nil }
}

struct AIFileIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  init?(_ url: URL) {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let device = attrs[.systemNumber] as? NSNumber,
      let inode = attrs[.systemFileNumber] as? NSNumber
    else { return nil }
    self.device = device.uint64Value
    self.inode = inode.uint64Value
  }
}

public enum AIWorktrees {
  private static let logger = Logger(subsystem: "work.12306.xstats", category: "ai-cleanup")

  static func discover(roots: [URL], home: String, excludedPaths: [String], budget: AIScanBudget)
    throws -> (
      items: [AIWorktree], incomplete: Bool
    )
  {
    var repositories: [URL] = []
    var visited = Set<String>()
    var incomplete = false
    // 只搜索选定根的有限层级；遇到仓库后停止深入，避免遍历依赖和构建产物。
    var stack = roots.reversed().map { ($0, 0) }
    let discoveryBudget = AIScanBudget(
      seconds: 5, entries: 5_000, deadline: budget.deadline, parent: budget)
    do {
      while let (directory, depth) = stack.popLast() {
        try discoveryBudget.check()
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else {
          incomplete = true
          continue
        }
        guard visited.insert(directory.standardizedFileURL.path).inserted else { continue }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
          repositories.append(directory)
          guard repositories.count < 80 else { throw AIScanError.limit }
          let nested = directory.appendingPathComponent(".claude/worktrees")
          if FileManager.default.fileExists(atPath: nested.path) { stack.append((nested, 0)) }
          continue
        }
        guard depth < 4 else { continue }
        guard
          let children = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
              incomplete = true
              return false
            })
        else {
          incomplete = true
          continue
        }
        for case let child as URL in children {
          try discoveryBudget.check()
          if ["node_modules", "vendor", "build", "target", "dist", "Library"].contains(
            child.lastPathComponent)
          {
            continue
          }
          let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          if values.isDirectory == true, values.isSymbolicLink != true {
            stack.append((child, depth + 1))
          }
        }
      }
    } catch is CancellationError { throw CancellationError() } catch { incomplete = true }
    var items: [AIWorktree] = []
    var seenCommon = Set<String>()
    var seenPaths = Set<String>()
    for repository in repositories {
      try Task.checkCancellation()
      do {
        try budget.check()
        let list = try AIGit.run(
          ["worktree", "list", "--porcelain", "-z"], in: repository, home: home,
          deadline: budget.deadline)
        let records = try parse(list)
        guard let primary = records.first, let mainPath = primary["worktree"] else {
          incomplete = true
          continue
        }
        guard primary["bare"] == nil else {
          incomplete = true
          continue
        }
        let main = URL(fileURLWithPath: mainPath).standardizedFileURL
        guard seenCommon.insert(main.path).inserted else { continue }
        for record in records.dropFirst() {
          try Task.checkCancellation()
          guard let path = record["worktree"], let head = record["HEAD"],
            seenPaths.insert(path).inserted
          else { continue }
          guard items.count < 200 else { throw AIScanError.limit }
          let url = URL(fileURLWithPath: path).standardizedFileURL
          let branch = record["branch"].map { String($0.dropFirst("refs/heads/".count)) }
          let size = try? AIScanBudget(
            seconds: 1, entries: 10_000, deadline: budget.deadline, parent: budget
          ).size(
            url)
          let base = AIWorktree(
            url: url, repository: main, branch: branch, head: head, bytes: size,
            protection: record["locked"] != nil ? .locked : nil,
            identity: AIFileIdentity(url),
            gitIdentity: AIFileIdentity(url.appendingPathComponent(".git")),
            commonIdentity: AIFileIdentity(main.appendingPathComponent(".git")))
          let protection: AIWorktree.Protection?
          do {
            try check(base, home: home, excludedPaths: excludedPaths, deadline: budget.deadline)
            protection = nil
          } catch let reason as AIWorktree.Protection {
            protection = reason
          } catch is CancellationError { throw CancellationError() } catch {
            protection = .unavailable
          }
          items.append(
            AIWorktree(
              url: url, repository: main, branch: branch, head: head, bytes: size,
              protection: protection, identity: base.identity, gitIdentity: base.gitIdentity,
              commonIdentity: base.commonIdentity))
          if size == nil || protection == .unavailable { incomplete = true }
        }
      } catch is CancellationError { throw CancellationError() } catch { incomplete = true }
    }
    return (items.sorted { $0.url.path < $1.url.path }, incomplete)
  }

  /// 确认前与执行前均调用。目录身份、Git 登记、HEAD 与所有文件状态必须仍匹配。
  @concurrent
  public static func validateRemoval(
    _ worktree: AIWorktree, home: String = NSHomeDirectory(), excludedPaths: [String] = []
  )
    async throws
  {
    try check(
      worktree, home: home, excludedPaths: excludedPaths, deadline: Date().addingTimeInterval(15))
  }

  @concurrent
  public static func remove(
    _ worktree: AIWorktree, home: String = NSHomeDirectory(), excludedPaths: [String] = []
  ) async throws {
    do {
      let deadline = Date().addingTimeInterval(30)
      try check(worktree, home: home, excludedPaths: excludedPaths, deadline: deadline)
      try Task.checkCancellation()
      // 不传 --force，不删除分支，不自行删除目录；最终保护仍由 Git 执行。
      _ = try AIGit.run(
        ["worktree", "remove", "--", worktree.url.path], in: worktree.repository, home: home,
        deadline: deadline)
      guard !FileManager.default.fileExists(atPath: worktree.url.path) else {
        throw AIWorktree.Protection.unavailable
      }
      logger.info("Worktree removal completed")
    } catch {
      logger.error("Worktree removal did not complete; refresh required")
      throw error
    }
  }

  private static func check(
    _ item: AIWorktree, home: String, excludedPaths: [String], deadline: Date
  ) throws {
    try Task.checkCancellation()
    if CleanupExclusions.overlaps(item.url, paths: excludedPaths) {
      throw AIWorktree.Protection.excluded
    }
    if item.protection == .locked { throw AIWorktree.Protection.locked }
    let homeURL = URL(fileURLWithPath: home).standardizedFileURL
    for url in [item.url, item.repository] {
      guard url.path.hasPrefix(homeURL.path + "/"), url.path == url.resolvingSymlinksInPath().path
      else { throw AIWorktree.Protection.outsideHome }
    }
    for git in [
      item.url.appendingPathComponent(".git"), item.repository.appendingPathComponent(".git"),
    ] {
      guard git.path == git.resolvingSymlinksInPath().path else {
        throw AIWorktree.Protection.unavailable
      }
    }
    guard item.url != item.repository, let identity = item.identity,
      AIFileIdentity(item.url) == identity,
      let gitIdentity = item.gitIdentity,
      AIFileIdentity(item.url.appendingPathComponent(".git")) == gitIdentity,
      let commonIdentity = item.commonIdentity,
      AIFileIdentity(item.repository.appendingPathComponent(".git")) == commonIdentity,
      (try? item.url.appendingPathComponent(".git").resourceValues(forKeys: [.isRegularFileKey])
        .isRegularFile) == true,
      (try? item.repository.appendingPathComponent(".git").resourceValues(forKeys: [.isDirectoryKey]
      ).isDirectory) == true
    else { throw AIWorktree.Protection.unavailable }
    let common = try AIGit.run(
      ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: item.url, home: home,
      deadline: deadline)
    let commonPath = String(decoding: common, as: UTF8.self).trimmingCharacters(in: .newlines)
    guard
      URL(fileURLWithPath: commonPath).standardizedFileURL.path
        == item.repository.appendingPathComponent(".git").path
    else { throw AIWorktree.Protection.unavailable }
    let top = try AIGit.run(
      ["rev-parse", "--show-toplevel"], in: item.url, home: home, deadline: deadline)
    guard
      URL(fileURLWithPath: String(decoding: top, as: UTF8.self).trimmingCharacters(in: .newlines))
        .standardizedFileURL.path == item.url.path
    else { throw AIWorktree.Protection.unavailable }
    let records = try parse(
      AIGit.run(
        ["worktree", "list", "--porcelain", "-z"], in: item.repository, home: home,
        deadline: deadline))
    guard
      let current = records.dropFirst().first(where: {
        $0["worktree"].map { URL(fileURLWithPath: $0).standardizedFileURL.path } == item.url.path
      }), current["HEAD"] == item.head,
      current["branch"].map({ String($0.dropFirst("refs/heads/".count)) }) == item.branch
    else { throw AIWorktree.Protection.unavailable }
    if current["locked"] != nil { throw AIWorktree.Protection.locked }
    if FileManager.default.fileExists(atPath: item.url.appendingPathComponent(".gitmodules").path) {
      throw AIWorktree.Protection.submodule
    }
    // 自定义 clean/process 过滤器可能在 status 刷新索引时执行外部命令；不启动仓库代码。
    let filters = try AIGit.run(
      ["config", "--get-regexp", "^filter\\..*\\.(clean|process)$"], in: item.url, home: home,
      deadline: deadline, allowedStatuses: [0, 1])
    guard filters.isEmpty else { throw AIWorktree.Protection.unavailable }
    // assume-unchanged / skip-worktree 能让 status 隐藏实际修改，存在这些标记时保守拦截。
    let tracked = try AIGit.run(
      ["ls-files", "-v", "-z"], in: item.url, home: home, deadline: deadline)
    guard
      !tracked.split(separator: 0).contains(where: { entry in
        guard let flag = entry.first else { return true }
        return flag == 83 || (97...122).contains(flag)
      })
    else { throw AIWorktree.Protection.changed }
    let status = try AIGit.run(
      [
        "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching",
        "--ignore-submodules=none",
      ], in: item.url, home: home, deadline: deadline)
    guard status.isEmpty else { throw AIWorktree.Protection.changed }
    if item.branch == nil {
      let refs = try AIGit.run(
        [
          "for-each-ref", "--contains", item.head, "--format=%(refname)", "refs/heads", "refs/tags",
          "refs/remotes",
        ], in: item.url, home: home, deadline: deadline)
      guard !refs.isEmpty else { throw AIWorktree.Protection.detached }
    }
    try Task.checkCancellation()
  }

  static func parse(_ data: Data) throws -> [[String: String]] {
    guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\0\0") else {
      throw AIWorktree.Protection.unavailable
    }
    return text.components(separatedBy: "\0\0").filter { !$0.isEmpty }.map { record in
      Dictionary(
        record.split(separator: "\0").map { field in
          let parts = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
          return (String(parts[0]), parts.count == 2 ? String(parts[1]) : "")
        }, uniquingKeysWith: { first, _ in first })
    }
  }
}

/// 专用 Git 执行器：完整输出才可授权删除，截断、超时、取消和非零退出均拒绝。
enum AIGit {
  static func run(
    _ arguments: [String], in directory: URL, home: String, deadline: Date,
    allowedStatuses: Set<Int32> = [0]
  ) throws -> Data {
    try Task.checkCancellation()
    let end = min(
      deadline, Date().addingTimeInterval(arguments.prefix(2) == ["worktree", "remove"] ? 30 : 5))
    guard Date() < end else { throw AIScanError.limit }
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
      "xstats-ai-git-" + UUID().uuidString)
    guard
      FileManager.default.createFile(
        atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw AIWorktree.Protection.unavailable }
    defer { try? FileManager.default.removeItem(at: output) }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments =
      [
        "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
        "-c", "core.hooksPath=/dev/null", "-C", directory.path,
      ] + arguments
    // 不继承 GIT_DIR/GIT_INDEX_FILE/GIT_CONFIG_* 等外部覆盖，亦不触发用户的全局钩子。
    process.environment = [
      "HOME": home, "PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0",
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
      "GIT_LITERAL_PATHSPECS": "1",
    ]
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
          Darwin.kill(process.processIdentifier, SIGKILL)
          _ = finished.wait(timeout: .now() + 2)
        }
      }
    }
    while finished.wait(timeout: .now() + 0.05) == .timedOut {
      try Task.checkCancellation()
      guard Date() < end, try handle.offset() <= 1_048_576 else { throw AIScanError.limit }
    }
    try Task.checkCancellation()
    guard allowedStatuses.contains(process.terminationStatus), try handle.offset() <= 1_048_576
    else { throw AIWorktree.Protection.unavailable }
    return try Data(contentsOf: output)
  }
}
