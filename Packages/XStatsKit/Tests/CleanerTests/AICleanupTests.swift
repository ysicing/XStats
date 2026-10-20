// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct AICleanupTests {
  @Test func desktopDetectionStopsWhenItsDeadlineHasExpired() throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let result = try AIAgentCleanup.desktopApplications(
      in: [fixture.home], budget: AIScanBudget(deadline: .distantPast))
    #expect(result.incomplete)
    #expect(result.applications.isEmpty)
  }

  @Test func truncatedDesktopDetectionMarksScanIncompleteAndStillFindsWorktrees() async throws {
    let fixture = try AICleanupFixture(git: true)
    defer { fixture.dispose() }
    let applications = fixture.home.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    for index in 0..<1_001 {
      try Data().write(to: applications.appendingPathComponent("entry-\(index)"))
    }
    var environment = fixture.environment
    environment.applicationDirectories = [applications]
    let result = try await AIAgentCleanup.scan(environment: environment)
    #expect(result.incomplete)
    #expect(result.worktrees.count == 1)
    #expect(result.worktrees.first?.canRemove == true)
  }

  @Test func largeToolCatalogCannotStarveWorktreeDiscovery() async throws {
    let fixture = try AICleanupFixture(git: true)
    defer { fixture.dispose() }
    let seed = fixture.home.appendingPathComponent("seed")
    try Data(repeating: 1, count: 4096).write(to: seed)
    // 三个目录各自在单目录上限以内，但总条目超过工具统计预算。
    for name in [".codex", ".claude", ".grok"] {
      let root = fixture.home.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      for index in 0..<25_000 {
        try FileManager.default.linkItem(at: seed, to: root.appendingPathComponent("file-\(index)"))
      }
    }
    var environment = fixture.environment
    environment.executable = {
      ["codex", "claude", "grok"].contains($0) ? URL(fileURLWithPath: "/fixture/" + $0) : nil
    }
    let result = try await AIAgentCleanup.scan(environment: environment)
    #expect(result.incomplete)
    #expect(result.tools.contains { !$0.dataDirectories.isEmpty && $0.bytes == nil })
    #expect(result.worktrees.count == 1)
    #expect(result.worktrees.first?.canRemove == true)
  }

  @Test func desktopDetectionUsesBundleIdentityAndRequiresAnExecutable() async throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let applications = fixture.home.appendingPathComponent("Applications")
    let bundles = [
      ("Renamed Codex", "com.openai.codex", true),
      ("Renamed Editor", "com.microsoft.VSCode", true),
      ("Assistant", "com.anthropic.claudefordesktop", true),
      ("Harness", "com.deepseek.dsh", true),
      ("Cindy", "unrelated.cindy", true),
      ("Buddy", "com.tencent.codebuddycn", true),
      ("International Buddy", "com.workbuddy.workbuddy", true),
      ("Incomplete", "com.tencent.workbuddy.mac", false),
    ]
    for (name, identifier, runnable) in bundles {
      let contents = applications.appendingPathComponent("\(name).app/Contents")
      try FileManager.default.createDirectory(
        at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
      let plist: [String: String] = [
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "fixture",
        "CFBundlePackageType": "APPL",
      ]
      try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
      if runnable {
        let executable = contents.appendingPathComponent("MacOS/fixture")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: executable.path)
      }
    }
    var environment = fixture.environment
    environment.applicationDirectories = [applications]
    let result = try await AIAgentCleanup.scan(environment: environment)
    #expect(
      Set(result.tools.map(\.id)) == [
        "codex", "vscode", "claude-desktop", "deepseek", "codebuddy", "workbuddy",
      ])
    #expect(!result.tools.contains { $0.id == "claude" })
    #expect(!result.tools.contains { $0.id == "cindy" })
    #expect(
      result.tools.first { $0.id == "codex" }?.applicationURL?.resolvingSymlinksInPath().path
        == applications.appendingPathComponent("Renamed Codex.app").resolvingSymlinksInPath().path)
    #expect(
      result.tools.first { $0.id == "vscode" }?.applicationURL?.resolvingSymlinksInPath().path
        == applications.appendingPathComponent("Renamed Editor.app").resolvingSymlinksInPath().path)
    #expect(
      result.tools.first { $0.id == "workbuddy" }?.applicationURL?.resolvingSymlinksInPath().path
        == applications.appendingPathComponent("International Buddy.app").resolvingSymlinksInPath()
        .path)
  }

  @Test func additionalToolDataIsReadOnlyAndVSCodeScopeExcludesSharedEditorData() async throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let relatives = [
      ".grok", ".dsh", ".pi/agent", ".cindy", ".codebuddy", ".codebuddycn", ".workbuddy",
      "Library/Application Support/Claude", "Library/Application Support/CindyGlobal",
      "Library/Application Support/com.workbuddy.workbuddy",
      "Library/Application Support/Code/User/globalStorage/github.copilot-chat",
      "Library/Application Support/Code/User/workspaceStorage",
    ]
    for relative in relatives {
      let directory = fixture.home.appendingPathComponent(relative)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(
        to: directory.appendingPathComponent("session.json"))
    }
    var environment = fixture.environment
    environment.executable = {
      ["grok", "dsh", "pi", "codebuddy", "code"].contains($0)
        ? URL(fileURLWithPath: "/fixture/" + $0) : nil
    }
    let result = try await AIAgentCleanup.scan(environment: environment)
    #expect(Set(result.tools.map(\.id)) == ["grok", "deepseek", "pi", "codebuddy", "vscode"])
    for id in ["grok", "deepseek", "pi", "codebuddy", "vscode"] {
      let tool = try #require(result.tools.first { $0.id == id })
      #expect(tool.installation == .installed)
      #expect((tool.bytes ?? 0) > 0)
    }
    let vscode = try #require(result.tools.first { $0.id == "vscode" })
    #expect(vscode.dataDirectories.count == 1)
    #expect(vscode.dataDirectories.first?.lastPathComponent == "github.copilot-chat")
    #expect(!result.incomplete)
  }

  @Test func additionalCustomHomesAndCrossToolOverlapDoNotDoubleCount() async throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let shared = fixture.home.appendingPathComponent("shared")
    let pi = fixture.home.appendingPathComponent("pi-custom")
    for root in [shared, pi] {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("state"))
    }
    var environment = fixture.environment
    environment.variables = [
      "GROK_HOME": shared.path, "DSH_HOME": shared.path, "PI_CODING_AGENT_DIR": pi.path,
    ]
    environment.executable = {
      ["grok", "dsh", "pi"].contains($0) ? URL(fileURLWithPath: "/fixture/" + $0) : nil
    }
    let result = try await AIAgentCleanup.scan(environment: environment)
    #expect(result.installedCount == 3)
    #expect(result.tools.first { $0.id == "grok" }?.dataDirectories.map(\.path) == [shared.path])
    #expect((result.tools.first { $0.id == "grok" }?.bytes ?? 0) > 0)
    #expect(result.tools.first { $0.id == "deepseek" }?.bytes == nil)
    #expect(result.tools.first { $0.id == "pi" }?.dataDirectories.map(\.path) == [pi.path])
    #expect(result.incomplete)
  }

  @Test func listsOnlyInstalledToolsAndHonorsCustomHome() async throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let custom = fixture.home.appendingPathComponent("custom-codex")
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: custom.appendingPathComponent("session"))
    try FileManager.default.createDirectory(
      at: fixture.home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
    var environment = fixture.environment
    environment.variables = ["CODEX_HOME": custom.path]
    // 残留目录不代表仍安装工具，未使用过的已安装工具仍应列出。
    environment.executable = { $0 == "claude" ? URL(fileURLWithPath: "/fixture/claude") : nil }
    let result = try await AIAgentCleanup.scan(environment: environment)
    #expect(result.installedCount == 1)
    #expect(result.tools.map(\.id) == ["claude"])
    #expect(result.tools.first?.dataDirectories.isEmpty == true)
    #expect(result.tools.first?.bytes == 0)
    #expect(result.tools.first?.applicationURL == nil)
    environment.executable = { $0 == "codex" ? URL(fileURLWithPath: "/fixture/codex") : nil }
    let updated = try await AIAgentCleanup.scan(environment: environment)
    #expect(updated.tools.map(\.id) == ["codex"])
    #expect(updated.tools.first?.dataDirectories.map(\.path) == [custom.path])
    #expect((updated.tools.first?.bytes ?? 0) > 0)
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
    #expect(throws: AIScanError.limit) {
      try AIScanBudget(deadline: .distantPast).size(directory)
    }
    #expect(throws: AIScanError.limit) {
      try AIScanBudget(parent: AIScanBudget(entries: 0)).size(directory)
    }
  }

  @Test func codexDataWithMoreThanTenThousandEntriesIsFullyMeasured() async throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let directory = fixture.home.appendingPathComponent(".codex/.tmp")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let payload = Data(repeating: 1, count: 4096)
    var expectedBytes: UInt64 = 0
    // Codex 的临时文件和插件会轻易超过旧条目上限，但仍可在时间预算内完成计量。
    for index in 0..<10_001 {
      let file = directory.appendingPathComponent("file-\(index)")
      try payload.write(to: file)
      expectedBytes += UInt64(
        try file.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize ?? 0)
    }
    var environment = fixture.environment
    environment.codexDesktopInstalled = { true }
    let scan = try await AIAgentCleanup.scan(environment: environment)
    let codex = try #require(scan.tools.first { $0.id == "codex" })
    #expect(codex.bytes == expectedBytes)
    #expect(!scan.incomplete)
  }

  @Test func measurementExcludesOnlyTopLevelWorktreesAndDoesNotFollowLinks() throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let root = fixture.home.appendingPathComponent(".codex")
    var expectedBytes: UInt64 = 0
    for relative in ["worktrees/managed", "plugins/worktrees/data", "worktrees-backup/data"] {
      let file = root.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: file)
      if relative != "worktrees/managed" {
        expectedBytes += UInt64(
          try file.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize ?? 0)
      }
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linked"),
      withDestinationURL: root.appendingPathComponent("worktrees-backup"))
    #expect(try AIScanBudget().size(root, excludingWorktrees: true) == expectedBytes)
    #expect(try AIScanBudget().size(root) > expectedBytes)
  }

  @Test func toolInventoryPreservesDataAndLogPathsAreNotCleanable() async throws {
    let fixture = try AICleanupFixture()
    defer { fixture.dispose() }
    let roots = [".codex/log", ".claude/debug", ".local/share/opencode/log"]
    let names = ["old.log", "recent.log", "auth.json", "state.sqlite", "session.jsonl"]
    let payload = Data(repeating: 1, count: 4096)
    let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
    for relative in roots {
      let root = fixture.home.appendingPathComponent(relative)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      for name in names {
        let file = root.appendingPathComponent(name)
        try payload.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
      }
    }
    var environment = fixture.environment
    environment.executable = {
      ["codex", "claude", "opencode"].contains($0) ? URL(fileURLWithPath: "/fixture/" + $0) : nil
    }
    let scan = try await AIAgentCleanup.scan(environment: environment)
    #expect(Set(scan.tools.map(\.id)) == ["codex", "claude", "opencode"])
    for relative in roots {
      let root = fixture.home.appendingPathComponent(relative)
      #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set(names))
      for name in names {
        let file = root.appendingPathComponent(name)
        #expect(try Data(contentsOf: file) == payload)
        #expect(
          try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            == oldDate)
        #expect(throws: SafetyError.self) {
          try SafetyGuard(home: fixture.home.path).validate(file)
        }
      }
    }
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
    environment.codexDesktopInstalled = { true }
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
      hasGit: { usesGit }, codexDesktopInstalled: { false }, applicationDirectories: [])
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
