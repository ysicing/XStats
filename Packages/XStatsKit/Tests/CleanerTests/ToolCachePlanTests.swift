// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Darwin
import Testing
@testable import Cleaner

struct ToolCachePlanTests {
  @Test func cachePathValidationWorksInOptimizedBuilds() throws {
    // 必须同时在 Debug / Release 下运行；保护校验不能把所有正常路径都拒绝。
    let home = "/Users/cleanup-fixture"
    for path in [home + "/.npm", home + "/Library/Caches/go-build", "/tmp/cache with spaces"] {
      let validated = try ToolCachePlan.validatedPath(path, home: home)
      #expect(
        validated.path
          == URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path)
    }
    for path in ["/", home, "/Users", "relative", home + "/bad\npath", home + "/bad\0path"] {
      #expect(throws: ToolCachePlanError.self) { try ToolCachePlan.validatedPath(path, home: home) }
    }
  }

  @Test(arguments: [false, true])
  func goBuildCacheUsesCanonicalPathOrOff(_ disabled: Bool) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let original = home.appendingPathComponent("A")
    let protected = home.appendingPathComponent("B")
    let alias = home.appendingPathComponent("alias")
    for url in [original, protected] {
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try fm.createSymbolicLink(at: alias, withDestinationURL: original)
    let env = CleanEnvironment(
      home: home.path, runningBundleIdentifiers: { [] },
      runTool: { _, _ in
        let paths = [
          "GOCACHE": disabled ? "off" : alias.path,
          "GOMODCACHE": home.appendingPathComponent("modules").path,
        ]
        return ToolRunResult(
          status: 0, output: String(decoding: try JSONEncoder().encode(paths), as: UTF8.self))
      },
      runToolWithEnvironment: { _, _, overrides in
        #expect(overrides["GOCACHE"] == (disabled ? "off" : original.path))
        return ToolRunResult(status: 0, output: "")
      }, excludedPaths: [protected.path])
    let prepare = try #require(DeveloperCleanupCatalog.goCache.prepareTool)
    let plan = try await prepare(env)
    try fm.removeItem(at: alias)
    try fm.createSymbolicLink(at: alias, withDestinationURL: protected)
    #expect(!plan.roots.contains { CleanupExclusions.overlaps($0, paths: env.excludedPaths) })
    _ = try await plan.execute(in: env)
    // 比较清理路径，避免不同 Foundation 版本对目录 URL 的末尾斜杠处理影响断言。
    #expect(plan.roots.contains { $0.path == original.path } == !disabled)
  }

  @Test(arguments: ["pnpm", "yarn"])
  func versionedCachePreviewMatchesNativeDeletionScope(_ tool: String) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let configured = home.appendingPathComponent("cache")
    let current = configured.appendingPathComponent("v10")
    let sibling = configured.appendingPathComponent("old")
    for url in [current, sibling] {
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
      try Data(repeating: 1, count: url == current ? 4096 : 16384).write(
        to: url.appendingPathComponent("data"))
    }
    let env = CleanEnvironment(
      home: home.path, runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
      runTool: { _, args in
        if args == ["--version"] { return ToolRunResult(status: 0, output: "1.22.22") }
        let flag = tool == "pnpm" ? "--store-dir" : "--cache-folder"
        let root =
          args.firstIndex(of: flag).map { URL(fileURLWithPath: args[$0 + 1]) } ?? configured
        return ToolRunResult(status: 0, output: root.appendingPathComponent("v10").path)
      })
    let rule = try #require(RuleCatalog.rules().first { $0.requiredTool == tool })
    let scans = await CleanEngine.scan([rule], environment: env)
    // Yarn Classic 删除配置根，pnpm prune 只处理当前版本存储。
    let expectedRoot = tool == "pnpm" ? current : configured
    #expect(scans[0].items.map(\.url.path) == [expectedRoot.path])
    #expect(scans[0].totalSize == CleanEngine.allocatedSize(of: expectedRoot))
    var excluded = env
    excluded.excludedPaths = [sibling.path]
    let protected = await CleanEngine.scan([rule], environment: excluded)
    #expect(protected[0].isCleanable == (tool == "pnpm"))
  }

  @Test func customToolCacheIsNotAlsoOfferedAsAnApplicationCache() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let cache = home.appendingPathComponent("Library/Caches/CustomUv")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data"))
    try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: cache.path)
    defer { try? fm.removeItem(at: home) }
    let environment = CleanEnvironment(
      home: home.path, runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
      runTool: { _, args in
        #expect(args == ["cache", "dir"])
        return ToolRunResult(status: 0, output: cache.path)
      })
    let scans = await CleanEngine.scan(
      [RuleCatalog.userCaches, DeveloperCleanupCatalog.uvCache], environment: environment)
    #expect(scans[0].items.isEmpty && scans[0].skippedCount == 1)
    #expect(scans[1].items.count == 1 && scans[1].isCleanable)
  }

  @Test func nestedGoCacheRootsAreSizedOnce() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let modules = home.appendingPathComponent("Custom/modules")
    let build = modules.appendingPathComponent("build")
    try fm.createDirectory(at: build, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: build.appendingPathComponent("data"))
    defer { try? fm.removeItem(at: home) }
    let environment = CleanEnvironment(
      home: home.path, runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
      runTool: { _, _ in
        let paths = ["GOCACHE": build.path, "GOMODCACHE": modules.path]
        return ToolRunResult(
          status: 0, output: String(decoding: try JSONEncoder().encode(paths), as: UTF8.self))
      })
    let scans = await CleanEngine.scan([DeveloperCleanupCatalog.goCache], environment: environment)
    #expect(scans[0].items.count == 1)
    #expect(scans[0].totalSize == CleanEngine.allocatedSize(of: modules))
  }

  @Test func bunRunnerUsesAnIsolatedProjectAndReleasesIt() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let executable = home.appendingPathComponent(".local/bin/bun")
    try fm.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    try Data(
      "#!/bin/sh\n[ -f package.json ] || exit 2\nprintf '%s\\n%s\\n' \"$BUN_INSTALL_CACHE_DIR\" \"$PWD\"\n"
        .utf8
    ).write(to: executable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let cache = home.appendingPathComponent("Custom/cache").path
    let result = try await DeveloperToolRunner.run(
      "bun", arguments: ["pm", "cache"], home: home.path,
      environmentOverrides: ["BUN_INSTALL_CACHE_DIR": cache], timeout: 2)
    let lines = result.output.split(separator: "\n")
    try #require(lines.count == 2)
    #expect(String(lines[0]) == cache)
    #expect(!fm.fileExists(atPath: String(lines[1])))
  }

  @Test(.timeLimit(.minutes(1))) func queryTimeoutAlsoStopsReadingAnInheritedOutputPipe()
    async throws
  {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let executable = home.appendingPathComponent(".local/bin/uv")
    try fm.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer {
      if let value = try? String(contentsOf: home.appendingPathComponent("child"), encoding: .utf8),
        let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        kill(pid, SIGKILL)
      }
      try? fm.removeItem(at: home)
    }
    try Data("#!/bin/sh\n/bin/sleep 30 &\necho $! > \"$HOME/child\"\nexit 0\n".utf8).write(
      to: executable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    do {
      // 留出子进程启动时间，使并行 CI 覆盖继承管道，而非仅覆盖启动期间的超时。
      _ = try await DeveloperToolRunner.run(
        "uv", arguments: ["cache", "dir"], home: home.path, timeout: 2)
      Issue.record("Query waited for a background process instead of timing out")
    } catch ToolExecutionError.timedOut(let tool) { #expect(tool == "uv") }
    let value = try String(contentsOf: home.appendingPathComponent("child"), encoding: .utf8)
    let pid = try #require(Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)))
    // 验证仍持有写端的子进程尚未退出，而非把 CI 线程调度延迟当成超时逻辑失败。
    #expect(kill(pid, 0) == 0, "查询应在子进程释放输出管道之前返回超时")
  }

  @Test(arguments: ["npm", "yarn", "pnpm", "bun", "go", "cargo-cache", "uv"])
  func configuredPathsAreScannedPinnedAndProtected(_ tool: String) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let configured = home.appendingPathComponent("Custom/" + tool)
    let scanned: URL
    switch tool {
    case "npm": scanned = configured.appendingPathComponent("_cacache")
    case "yarn": scanned = configured.appendingPathComponent("v6")
    case "pnpm": scanned = configured.appendingPathComponent("v10")
    case "go": scanned = configured.appendingPathComponent("build")
    case "cargo-cache": scanned = configured.appendingPathComponent("registry")
    default: scanned = configured
    }
    try fm.createDirectory(at: scanned, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: scanned.appendingPathComponent("data"))
    let commands = ToolCommandCapture()
    let runner: @Sendable (String, [String]) async throws -> ToolRunResult = { _, args in
      if args == ["--version"] { return ToolRunResult(status: 0, output: "1.22.22") }
      if args == ["env", "-json", "GOCACHE", "GOMODCACHE"] {
        let values = [
          "GOCACHE": scanned.path, "GOMODCACHE": configured.appendingPathComponent("modules").path,
        ]
        return ToolRunResult(
          status: 0, output: String(decoding: try JSONEncoder().encode(values), as: UTF8.self))
      }
      if args.contains("get") || args == ["cache", "dir"] || args == ["pm", "cache"]
        || args == ["store", "path"]
      {
        return ToolRunResult(status: 0, output: (tool == "npm" ? configured : scanned).path)
      }
      for flag in ["--store-dir", "--cache-folder"] {
        if let i = args.firstIndex(of: flag), !args.contains("clean"), !args.contains("prune") {
          let root = URL(fileURLWithPath: args[i + 1])
          return ToolRunResult(
            status: 0, output: root.appendingPathComponent(tool == "pnpm" ? "v10" : "v6").path)
        }
      }
      if tool == "bun", args == ["pm", "cache", "--cache-dir", configured.path] {
        return ToolRunResult(status: 0, output: configured.path)
      }
      await commands.record(args, overrides: [:])
      return ToolRunResult(status: 0, output: "")
    }
    var environment = CleanEnvironment(
      home: home.path, runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
      runTool: runner,
      runToolWithEnvironment: { _, args, overrides in
        await commands.record(args, overrides: overrides)
        return ToolRunResult(status: 0, output: "")
      }, toolEnvironment: ["CARGO_HOME": configured.path])
    let rule = try #require(RuleCatalog.rules().first { $0.requiredTool == tool })
    let scans = await CleanEngine.scan([rule], environment: environment)
    let scan = try #require(scans.first)
    try #require(scan.isCleanable && scan.toolCachePlan != nil)
    #expect(
      scan.items.contains {
        $0.url.path == scanned.path || scanned.path.hasPrefix($0.url.path + "/")
      })

    // 扫描后配置切到别处：执行仍必须使用已审阅计划中的目录。
    environment.inspectTool = { _, _ in
      ToolRunResult(status: 0, output: home.appendingPathComponent("NewCache").path)
    }
    let report = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.failures.isEmpty)
    let executions = await commands.values()
    try #require(executions.count == 1)
    if tool == "go" {
      #expect(executions[0].overrides["GOCACHE"] == scanned.path)
      #expect(
        executions[0].overrides["GOMODCACHE"] == configured.appendingPathComponent("modules").path)
    } else if tool == "cargo-cache" {
      #expect(executions[0].overrides["CARGO_HOME"] == configured.path)
    } else if tool == "bun" {
      #expect(executions[0].overrides["BUN_INSTALL_CACHE_DIR"] == configured.path)
    } else {
      #expect(executions[0].arguments.contains(configured.path))
    }
    environment.excludedPaths = [scanned.appendingPathComponent("data").path]
    let protected = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(protected.skippedCount > 0 && protected.removedCount == 0)
    #expect(await commands.values().count == 1)
  }

  @Test(arguments: ["", "relative/cache", "/", "/cache\nwarning", "undefined"])
  func invalidCacheQueryCannotAuthorizeCleanup(_ output: String) async throws {
    let environment = CleanEnvironment(
      home: "/Users/demo", runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
      runTool: { _, args in
        #expect(args == ["config", "get", "cache"])
        return ToolRunResult(status: 0, output: output)
      })
    let scan = await CleanEngine.scan([DeveloperCleanupCatalog.npmCache], environment: environment)
    #expect(scan.first?.blocked != nil && scan.first?.isCleanable == false)
  }

  @Test(arguments: ["developer.homebrew", "developer.yarn"])
  func unboundedNativeOperationsStopWhenExclusionsExist(_ id: String) async throws {
    // 只读预览仍可运行，以便保留范围供通用规则让出；任何清理命令都不能执行。
    let environment = CleanEnvironment(
      home: "/Users/demo", runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
      runTool: { _, args in
        switch args {
        case ["--version"]: return ToolRunResult(status: 0, output: "4.0.0")
        case ["--cache"]:
          return ToolRunResult(status: 0, output: "/Users/demo/Library/Caches/Homebrew")
        case ["config", "get", "cacheFolder", "--json"]:
          return ToolRunResult(status: 0, output: #""/Users/demo/.yarn/berry/cache""#)
        case ["config", "get", "globalFolder", "--json"]:
          return ToolRunResult(status: 0, output: #""/Users/demo/.yarn/berry""#)
        case ["cleanup", "--prune=30", "--dry-run"]:
          return ToolRunResult(
            status: 0,
            output: "Would remove: /Users/demo/Library/Caches/Homebrew/old (1KB)\n"
              + "==> This operation would free approximately 1KB of disk space.")
        default:
          Issue.record("Unexpected tool command \(args)")
          return ToolRunResult(status: 1, output: "")
        }
      },
      runToolWithEnvironment: { _, args, _ in
        Issue.record("A global operation ran despite exclusions: \(args)")
        return ToolRunResult(status: 0, output: "")
      }, excludedPaths: ["/Users/demo/Protected"])
    let rule = try #require(RuleCatalog.rules().first { $0.id == id })
    let scans = await CleanEngine.scan([rule], environment: environment)
    #expect(scans.first?.blocked != nil && scans.first?.isCleanable == false)
    #expect(scans.first?.toolCachePlan?.roots.isEmpty == false)
    let report = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.removedCount == 0)
  }
}

private actor ToolCommandCapture {
  struct Command: Sendable {
    let arguments: [String]
    let overrides: [String: String]
  }
  private var commands: [Command] = []
  func record(_ arguments: [String], overrides: [String: String]) {
    commands.append(Command(arguments: arguments, overrides: overrides))
  }
  func values() -> [Command] { commands }
}
