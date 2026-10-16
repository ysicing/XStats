// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct DeveloperCleanupCatalogTests {
  @Test func developerRulesHaveUniqueIdentitiesAndExplicitSources() {
    let rules = DeveloperCleanupCatalog.rules
    #expect(Set(rules.map(\.id)).count == rules.count)
    #expect(rules.allSatisfy { $0.category == .developer })
    #expect(rules.filter { $0.requiredTool != nil }.allSatisfy { $0.prepareTool != nil })
  }

  @Test func berryPreviewUsesConfiguredLocationsAndLateExclusionsStopExecution() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let cache = home.appendingPathComponent("custom-cache")
    let global = home.appendingPathComponent("custom-global")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("fixture.zip"))
    var environment = CleanEnvironment(
      home: home.path, runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
      runTool: { _, args in
        if args == ["--version"] { return ToolRunResult(status: 0, output: "4.0.0") }
        #expect(
          args == ["config", "get", "cacheFolder", "--json"]
            || args == ["config", "get", "globalFolder", "--json"])
        let path = args.contains("cacheFolder") ? cache.path : global.path
        return ToolRunResult(
          status: 0, output: String(decoding: try JSONEncoder().encode(path), as: UTF8.self))
      },
      runToolWithEnvironment: { _, args, overrides in
        #expect(args == ["cache", "clean", "--all"])
        #expect(overrides == ["YARN_CACHE_FOLDER": cache.path, "YARN_GLOBAL_FOLDER": global.path])
        return ToolRunResult(status: 0, output: "fixture: no deletion")
      })
    let rule = DeveloperCleanupCatalog.yarnCache
    let scans = await CleanEngine.scan([rule], environment: environment)
    try #require(scans[0].isCleanable)
    #expect(scans[0].items.map(\.url.path) == [cache.path])
    let first = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(first.failures.isEmpty)
    environment.excludedPaths = [home.appendingPathComponent("unrelated-kept-item").path]
    environment.runToolWithEnvironment = { _, _, _ in
      Issue.record("A global operation bypassed a late exclusion")
      return ToolRunResult(status: 0, output: "")
    }
    let second = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(second.failures.count == 1 && second.removedCount == 0)
  }

  @Test func nativeCleanupCannotRunWithoutTheReviewedPlan() async throws {
    let rule = try #require(RuleCatalog.rules().first { $0.id == "developer.npm" })
    let item = CleanItem(url: URL(fileURLWithPath: "/Users/demo/Cache"), size: 100)
    let scan = RuleScan(rule: rule, items: [item], skippedCount: 0, blocked: nil)
    let environment = CleanEnvironment(
      home: "/Users/demo", runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
      runTool: { _, _ in
        Issue.record("Native cleanup must never fall back to an unreviewed command")
        return ToolRunResult(status: 0, output: "")
      })
    let report = await CleanEngine.clean(
      [scan], selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.removedCount == 0 && report.failures.count == 1)
  }

  @Test func pipUsesTheConfiguredCacheWithoutTouchingEnvironments() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let cache = home.appendingPathComponent("Custom pip cache")
    let virtualEnvironment = home.appendingPathComponent("project/.venv/site-packages/keep.py")
    for url in [cache.appendingPathComponent("http-v2/data"), virtualEnvironment] {
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: url)
    }
    let rule = try #require(RuleCatalog.rules().first { $0.id == "developer.pip" })
    #expect(!rule.selectedByDefault && rule.usesToolCleaner)
    let environment = CleanEnvironment(
      home: home.path, runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
      runTool: { tool, args in
        #expect(tool == "pip3")
        if args == ["cache", "dir"] { return ToolRunResult(status: 0, output: cache.path) }
        #expect(args == ["cache", "purge", "--cache-dir", cache.path])
        return ToolRunResult(status: 0, output: "fixture: no deletion")
      })
    let scans = await CleanEngine.scan([rule], environment: environment)
    #expect(scans[0].items.map(\.url.path) == [cache.path])
    let report = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.failures.isEmpty && fm.fileExists(atPath: virtualEnvironment.path))
    var kept = environment
    kept.excludedPaths = [cache.appendingPathComponent("http-v2").path]
    let excluded = await CleanEngine.scan([rule], environment: kept)
    #expect(excluded[0].blocked == .excluded)
  }

  @Test(arguments: [
    ("developer.vscode", "Code", "com.microsoft.VSCode"),
    ("developer.cursor", "Cursor", "com.todesktop.230313mzl4w4u92"),
  ])
  func editorRulesOnlyDeleteExplicitCaches(_ fixture: (String, String, String)) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let base = home.appendingPathComponent("Library/Application Support/" + fixture.1)
    let cacheNames = ["Cache", "Code Cache", "GPUCache"]
    let preserved = [
      "User/settings.json", "User/globalStorage/session.db", "extensions/example/main.js",
      "workspaceStorage/state.db",
    ]
    for relative in cacheNames.map({ $0 + "/data" }) + preserved {
      let file = base.appendingPathComponent(relative)
      try fm.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: file)
      try fm.setAttributes(
        [.modificationDate: Date.distantPast], ofItemAtPath: file.deletingLastPathComponent().path)
    }
    let rule = try #require(RuleCatalog.rules().first { $0.id == fixture.0 })
    #expect(!rule.selectedByDefault && !rule.usesToolCleaner)
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let scans = await CleanEngine.scan([rule], environment: environment)
    #expect(Set(scans[0].items.map(\.url.lastPathComponent)) == Set(cacheNames))
    let blocked = await CleanEngine.scan(
      [rule],
      environment: CleanEnvironment(home: home.path, runningBundleIdentifiers: { [fixture.2] }))
    #expect(blocked[0].blocked != nil && !blocked[0].isCleanable)
    let report = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.removedCount == 3 && report.failures.isEmpty)
    #expect(preserved.allSatisfy { fm.fileExists(atPath: base.appendingPathComponent($0).path) })
  }
}
