// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct AICleanupTests {
  @Test func separatesInstalledToolsFromDataAndHonorsCustomHome() async throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let custom = fixture.home.appendingPathComponent("custom-codex")
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: custom.appendingPathComponent("session"))
    try FileManager.default.createDirectory(
      at: fixture.home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
    var environment = fixture.environment
    environment.variables = ["CODEX_HOME": custom.path]
    environment.executable = { $0 == "claude" ? URL(fileURLWithPath: "/fixture/claude") : nil }
    let result = try await AIAgentCleanup.scan(environment: environment)
    #expect(result.installedCount == 1)
    let codex = try #require(result.tools.first { $0.id == "codex" })
    #expect(codex.installation == .dataOnly)
    #expect(codex.dataDirectories.map(\.path) == [custom.path])
    #expect((codex.bytes ?? 0) > 0)
    #expect(result.tools.first { $0.id == "gemini" }?.installation == .dataOnly)
    #expect(result.tools.first { $0.id == "cursor" }?.installation == .absent)
    #expect(
      !AIAgentCleanup.logRules(environment: environment).contains { $0.id == "ai.logs.codex" })
  }

  @Test func scanDoesNotFollowLinksAndMarksBudgetExhaustion() throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let directory = fixture.home.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: directory.appendingPathComponent("file"))
    let link = fixture.home.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    #expect(throws: AIScanError.self) { try AIScanBudget().size(link) }
    #expect(throws: AIScanError.self) { try AIScanBudget(entries: 0).size(directory) }
  }

  @Test func logsPreserveSessionsCredentialsRecentFilesAndExclusions() async throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let root = fixture.home.appendingPathComponent(".codex/log")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["old.log", "recent.log", "auth.json", "state.sqlite", "session.jsonl"] {
      let file = root.appendingPathComponent(name)
      try Data(repeating: 1, count: 4096).write(to: file)
      if name != "recent.log" {
        try FileManager.default.setAttributes(
          [.modificationDate: Date().addingTimeInterval(-10 * 86_400)], ofItemAtPath: file.path)
      }
    }
    var environment = fixture.environment
    let scans = await CleanEngine.scan(
      AIAgentCleanup.logRules(environment: environment), environment: environment.clean)
    #expect(scans.flatMap(\.items).map { $0.url.lastPathComponent } == ["old.log"])
    // 定向替换回收器，只修改临时夹具，不访问真实废纸篓。
    environment.clean.trash = { try FileManager.default.removeItem(at: $0) }
    let report = await CleanEngine.clean(
      scans, selected: ["ai.logs.codex"], preferTrash: true, environment: environment.clean,
      log: nil)
    #expect(report.removedCount == 1)
    for name in ["recent.log", "auth.json", "state.sqlite", "session.jsonl"] {
      #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
    }
    environment.clean.excludedPaths = [root.path]
    let excluded = await CleanEngine.scan(
      AIAgentCleanup.logRules(environment: environment), environment: environment.clean)
    #expect(excluded.flatMap(\.items).isEmpty)
    #expect(throws: SafetyError.self) {
      try SafetyGuard(home: fixture.home.path).validate(
        fixture.home.appendingPathComponent(".codex/auth.json"))
    }
    #expect(throws: SafetyError.self) { try SafetyGuard(home: fixture.home.path).validate(root) }
  }

  @Test func cleanWorktreeRemovalKeepsBranchAndRepository() async throws {
    let fixture = try AICleanupFixture(git: true)
    defer { fixture.dispose() }
    let result = try await AIAgentCleanup.scan(environment: fixture.environment)
    #expect(result.worktrees.count == 1)
    let tree = try #require(result.worktrees.first)
    #expect(tree.canRemove)
    await #expect(throws: AIWorktree.Protection.excluded) {
      try await AIWorktrees.remove(
        tree, home: fixture.home.path,
        excludedPaths: [fixture.tree.appendingPathComponent("tracked").path])
    }
    try await AIWorktrees.validateRemoval(tree, home: fixture.home.path)
    try await AIWorktrees.remove(tree, home: fixture.home.path)
    #expect(!FileManager.default.fileExists(atPath: fixture.tree.path))
    #expect(FileManager.default.fileExists(atPath: fixture.repository.path))
    _ = try fixture.git(["show-ref", "--verify", "refs/heads/agent"], at: fixture.repository)
  }

  @Test(arguments: [
    "modified", "untracked", "ignored", "locked", "detached", "submodule", "assume-unchanged",
    "skip-worktree", "filter",
  ])
  func refusesUnsafeWorktrees(kind: String) async throws {
    let fixture = try AICleanupFixture(git: true)
    defer { fixture.dispose() }
    switch kind {
    case "modified":
      try Data("changed".utf8).write(to: fixture.tree.appendingPathComponent("tracked"))
    case "untracked": try Data("work".utf8).write(to: fixture.tree.appendingPathComponent("new"))
    case "ignored": try Data("build".utf8).write(to: fixture.tree.appendingPathComponent("ignored"))
    case "filter":
      _ = try fixture.git(
        ["config", "filter.fixture.clean", "touch should-never-exist"], at: fixture.tree)
    case "assume-unchanged", "skip-worktree":
      _ = try fixture.git(["update-index", "--" + kind, "tracked"], at: fixture.tree)
      try Data("hidden modification".utf8).write(to: fixture.tree.appendingPathComponent("tracked"))
    case "locked":
      _ = try fixture.git(["worktree", "lock", fixture.tree.path], at: fixture.repository)
    case "detached":
      _ = try fixture.git(["checkout", "--detach"], at: fixture.tree)
      _ = try fixture.git(["commit", "--allow-empty", "-m", "independent"], at: fixture.tree)
    default: try Data().write(to: fixture.tree.appendingPathComponent(".gitmodules"))
    }
    let scan = try await AIAgentCleanup.scan(environment: fixture.environment)
    let tree = try #require(scan.worktrees.first)
    #expect(!tree.canRemove)
    let expected: AIWorktree.Protection =
      switch kind {
      case "filter": .unavailable
      case "locked": .locked
      case "detached": .detached
      case "submodule": .submodule
      default: .changed
      }
    #expect(tree.protection == expected)
    await #expect(throws: (any Error).self) {
      try await AIWorktrees.remove(tree, home: fixture.home.path)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.tree.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.tree.appendingPathComponent("should-never-exist").path))
  }

  @Test func rechecksChangesLocksAndDirectoryIdentityAfterPreview() async throws {
    let fixture = try AICleanupFixture(git: true)
    defer { fixture.dispose() }
    let scan = try await AIAgentCleanup.scan(environment: fixture.environment)
    let tree = try #require(scan.worktrees.first)
    try Data("unsaved".utf8).write(to: fixture.tree.appendingPathComponent("new"))
    await #expect(throws: AIWorktree.Protection.changed) {
      try await AIWorktrees.remove(tree, home: fixture.home.path)
    }
    try FileManager.default.removeItem(at: fixture.tree.appendingPathComponent("new"))
    _ = try fixture.git(["worktree", "lock", fixture.tree.path], at: fixture.repository)
    await #expect(throws: AIWorktree.Protection.locked) {
      try await AIWorktrees.remove(tree, home: fixture.home.path)
    }
    _ = try fixture.git(["worktree", "unlock", fixture.tree.path], at: fixture.repository)
    let replaced = fixture.home.appendingPathComponent("original")
    try FileManager.default.moveItem(at: fixture.tree, to: replaced)
    try FileManager.default.createDirectory(at: fixture.tree, withIntermediateDirectories: true)
    await #expect(throws: AIWorktree.Protection.unavailable) {
      try await AIWorktrees.remove(tree, home: fixture.home.path)
    }
  }

  @Test func managedWorktreesAreNotCountedAgainAsToolDataAndGitListsAreDeduplicated() async throws {
    let fixture = try AICleanupFixture(git: true)
    defer { fixture.dispose() }
    let managed = fixture.home.appendingPathComponent(".codex/worktrees/hash/repo")
    try FileManager.default.createDirectory(
      at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try fixture.git(
      ["worktree", "move", fixture.tree.path, managed.path], at: fixture.repository)
    var environment = fixture.environment
    environment.searchRoots = [fixture.repository, managed]
    let scan = try await AIAgentCleanup.scan(environment: environment)
    #expect(scan.worktrees.count == 1)
    #expect(scan.tools.first { $0.id == "codex" }?.bytes == 0)
    #expect(scan.worktrees.first?.canRemove == true)
  }

  @Test func referencedDetachedHeadCanBeRemovedButOutsideHomeAndSymlinksCannot() async throws {
    let fixture = try AICleanupFixture(git: true)
    defer { fixture.dispose() }
    _ = try fixture.git(["checkout", "--detach"], at: fixture.tree)
    let scan = try await AIAgentCleanup.scan(environment: fixture.environment)
    let tree = try #require(scan.worktrees.first)
    #expect(tree.canRemove)
    await #expect(throws: AIWorktree.Protection.outsideHome) {
      try await AIWorktrees.validateRemoval(
        tree, home: fixture.home.appendingPathComponent("other").path)
    }
    let original = fixture.home.appendingPathComponent("original")
    try FileManager.default.moveItem(at: fixture.tree, to: original)
    try FileManager.default.createSymbolicLink(at: fixture.tree, withDestinationURL: original)
    await #expect(throws: AIWorktree.Protection.outsideHome) {
      try await AIWorktrees.validateRemoval(tree, home: fixture.home.path)
    }
    #expect(FileManager.default.fileExists(atPath: original.path))
  }

  @Test func cancellationAndMalformedGitOutputFailClosed() async throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    #expect(throws: (any Error).self) {
      try AIWorktrees.parse(Data("worktree /tmp\0HEAD abc".utf8))
    }
    let task = Task { try await AIAgentCleanup.scan(environment: fixture.environment) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}

private struct AICleanupFixture {
  let home: URL
  var repository: URL { home.appendingPathComponent("repo") }
  var tree: URL { home.appendingPathComponent("agent tree") }
  let usesGit: Bool
  var environment: AICleanupEnvironment {
    AICleanupEnvironment(
      home: home.path, variables: [:], searchRoots: [home], executable: { _ in nil },
      hasGit: { usesGit }, codexDesktopInstalled: { false })
  }
  init(git: Bool = false) throws {
    usesGit = git
    home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "xstats-ai-test-" + UUID().uuidString
    ).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    if git {
      try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
      _ = try self.git(["init", "-b", "main"], at: repository)
      try Data("initial".utf8).write(to: repository.appendingPathComponent("tracked"))
      try Data("ignored\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
      _ = try self.git(["add", "."], at: repository)
      _ = try self.git(["commit", "-m", "initial"], at: repository)
      _ = try self.git(["worktree", "add", "-b", "agent", tree.path], at: repository)
    }
  }
  @discardableResult func git(_ args: [String], at directory: URL) throws -> Data {
    try AIGit.run(
      ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"] + args, in: directory,
      home: home.path, deadline: Date().addingTimeInterval(10))
  }
  func dispose() { try? FileManager.default.removeItem(at: home) }
}
