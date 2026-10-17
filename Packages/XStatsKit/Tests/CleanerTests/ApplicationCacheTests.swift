// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct ApplicationCacheTests {
  @Test(arguments: [
    (
      "developer.vscode", "Code - Insiders", "com.microsoft.VSCodeInsiders",
      ["Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs"]
    ),
    (
      "developer.cursor", "Cursor", "com.todesktop.230313mzl4w4u92",
      ["Cache", "Code Cache", "GPUCache", "CachedExtensionVSIXs"]
    ),
    (
      "app.codebuddy", "CodeBuddy CN", "com.tencent.codebuddy",
      [
        "Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache",
        "DawnGraphiteCache", "DawnWebGPUCache",
      ]
    ),
    (
      "app.claude", "Claude", "com.anthropic.claudefordesktop",
      ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]
    ),
    (
      "app.antigravity", "Antigravity", "com.google.antigravity",
      ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"]
    ),
    (
      "app.codebuddy", "CodeBuddy", "com.tencent.codebuddy",
      [
        "Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache",
        "DawnGraphiteCache", "DawnWebGPUCache",
      ]
    ),
    ("app.slack", "Slack", "com.tinyspeck.slackmacgap", ["Cache"]),
    ("app.discord", "discord", "com.hnc.Discord", ["Cache"]),
    (
      "app.teamsClassic", "Microsoft/Teams", "com.microsoft.teams",
      ["Cache", "Code Cache", "GPUCache"]
    ),
  ])
  func cleansOnlyReviewedCaches(_ fixture: (String, String, String, [String])) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let base = home.appendingPathComponent("Library/Application Support/" + fixture.1)
    let preserved = [
      "Cookies", "Local Storage/session", "IndexedDB/data", "Service Worker/CacheStorage/data",
      "settings.json",
    ]
    for relative in fixture.3.map({ $0 + "/data" }) + preserved {
      let file = base.appendingPathComponent(relative)
      try fm.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: file)
      try fm.setAttributes(
        [.modificationDate: Date.distantPast], ofItemAtPath: file.deletingLastPathComponent().path)
    }
    let rule = try #require(RuleCatalog.rules().first { $0.id == fixture.0 })
    #expect(rule.selectedByDefault == false)
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let scans = await CleanEngine.scan([rule], environment: environment)
    #expect(Set(scans[0].items.map(\.url.lastPathComponent)) == Set(fixture.3))
    let running = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [fixture.2] })
    let blocked = await CleanEngine.scan([rule], environment: running)
    #expect(blocked[0].isCleanable == false)
    let reopened = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: running, log: nil)
    #expect(reopened.removedCount == 0)
    var excluded = environment
    excluded.excludedPaths = [base.appendingPathComponent("Cache/data").path]
    let kept = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: excluded, log: nil)
    #expect(kept.removedCount == fixture.3.count - 1)
    #expect(fm.fileExists(atPath: base.appendingPathComponent("Cache/data").path))
    let result = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(result.removedCount == 1)
    #expect(preserved.allSatisfy { fm.fileExists(atPath: base.appendingPathComponent($0).path) })
  }

  @Test func absentAndRecentlyModifiedCachesAreNotCleanable() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.slack" })
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let missing = await CleanEngine.scan([rule], environment: environment)
    #expect(missing[0].items.isEmpty && missing[0].blocked == nil)
    let cache = home.appendingPathComponent("Library/Application Support/Slack/Cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data"))
    let recent = await CleanEngine.scan([rule], environment: environment)
    #expect(recent[0].items.isEmpty && recent[0].skippedCount == 1)
    try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: cache.path)
    let scanned = await CleanEngine.scan([rule], environment: environment)
    try #require(scanned[0].items.count == 1)
    try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: cache.path)
    let result = await CleanEngine.clean(
      scanned, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(
      result.removedCount == 0 && fm.fileExists(atPath: cache.appendingPathComponent("data").path))
  }

  @Test(arguments: [false, true])
  func rejectsRedirectedApplicationDirectory(afterScan: Bool) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let base = home.appendingPathComponent("Library/Application Support/Slack")
    let cache = base.appendingPathComponent("Cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data"))
    try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: cache.path)
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.slack" })
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let scans = await CleanEngine.scan([rule], environment: environment)
    try #require(scans[0].items.count == 1)
    let other = home.appendingPathComponent("Library/Application Support/Other")
    try fm.moveItem(at: base, to: other)
    try fm.createSymbolicLink(at: base, withDestinationURL: other)
    if afterScan {
      let result = await CleanEngine.clean(
        scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
      #expect(result.removedCount == 0)
    } else {
      let redirected = await CleanEngine.scan([rule], environment: environment)
      #expect(redirected[0].isCleanable == false)
    }
    #expect(fm.fileExists(atPath: other.appendingPathComponent("Cache/data").path))
  }
  @Test func codexRootNeverFallsBackToGenericCleanup() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let root = home.appendingPathComponent("Library/Caches/Codex")
    let cache = root.appendingPathComponent("Default/Cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data"))
    try Data("session".utf8).write(to: root.appendingPathComponent("Cookies"))
    for url in [root, cache] {
      try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: url.path)
    }
    let generic = RuleCatalog.userCaches
    let environment = CleanEnvironment(
      home: home.path, runningBundleIdentifiers: { ["com.openai.codex"] })
    let scans = await CleanEngine.scan([generic], environment: environment)
    #expect(scans[0].items.isEmpty)
    // 模拟旧扫描清单：即使专属规则被阻止或未参与扫描，执行也不能绕过它。
    let stale = RuleScan(
      rule: generic, items: [CleanItem(url: root, size: 4096)], skippedCount: 0, blocked: nil)
    let report = await CleanEngine.clean(
      [stale], selected: [generic.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.removedCount == 0)
    #expect(fm.fileExists(atPath: root.appendingPathComponent("Cookies").path))
  }

  @Test func codexCleansSixLeavesAndPreservesProfileState() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let root = home.appendingPathComponent("Library/Caches/Codex")
    var caches: [URL] = []
    var retained: [URL] = []
    for profile in ["Default", "Default/Partitions/codex-browser-app", "codex-browser-app"] {
      for leaf in ["Cache", "Code Cache", "Local Storage", "IndexedDB"] {
        let directory = root.appendingPathComponent(profile + "/" + leaf)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: directory.appendingPathComponent("data"))
        try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: directory.path)
        if leaf == "Cache" || leaf == "Code Cache" {
          caches.append(directory)
        } else {
          retained.append(directory)
        }
      }
    }
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.codex" })
    let env = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let scans = await CleanEngine.scan([RuleCatalog.userCaches, rule], environment: env)
    #expect(scans[0].items.isEmpty)
    #expect(Set(scans[1].items.map(\.url.path)) == Set(caches.map(\.path)))
    let report = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: env, log: nil)
    #expect(report.removedCount == 6)
    #expect(retained.allSatisfy { fm.fileExists(atPath: $0.appendingPathComponent("data").path) })
  }

  @Test func appNameFallbackIsRefreshedForEveryCandidate() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let root = home.appendingPathComponent("Library/Application Support/Qoder")
    let leaves = [
      "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "CachedData",
      "CachedExtensionVSIXs",
    ]
    for leaf in leaves {
      let directory = root.appendingPathComponent(leaf)
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: directory.appendingPathComponent("data"))
      try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: directory.path)
    }
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.qoder" })
    let env = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let scans = await CleanEngine.scan([rule], environment: env)
    #expect(scans[0].items.count == 7)
    var running = env
    running.runningApplicationNames = { ["Qoder"] }
    let blocked = await CleanEngine.scan([rule], environment: running)
    #expect(blocked[0].blocked == .appRunning("Qoder"))
    let state = ApplicationLaunchFixture()
    let report = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: env, log: nil,
      refreshRunningApplicationNames: { await state.names() })
    #expect(report.removedCount == 1)
    #expect(report.skippedCount == 6)
  }

  @Test func genericRulesProtectFriendlyNamesHelpersAndAliases() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }
    let support = home.appendingPathComponent("Library/Application Support/Claude/Cache")
    let logs = home.appendingPathComponent("Library/Logs/Code")
    let cacheRoot = home.appendingPathComponent("Library/Caches")
    for directory in [support, logs, cacheRoot] {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: directory.appendingPathComponent("data"))
      try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: directory.path)
    }
    let alias = cacheRoot.appendingPathComponent("alias")
    try fm.createSymbolicLink(at: alias, withDestinationURL: support)
    let env = CleanEnvironment(
      home: home.path, runningBundleIdentifiers: { ["com.microsoft.VSCode.helper"] })
    let scans = await CleanEngine.scan([RuleCatalog.logs], environment: env)
    #expect(scans[0].items.isEmpty)
    #expect(CleanEngine.owningApp(of: logs, running: ["com.microsoft.VSCode.helper"]) != nil)
    #expect(
      CleanEngine.owningApp(
        of: cacheRoot.appendingPathComponent("unknown-app"), running: [], names: ["unknown-app"])
        != nil)
    let generic = RuleCatalog.userCaches
    let reason = CleanEngine.skipReason(
      for: alias, rule: generic, running: [], environment: env, safety: SafetyGuard(home: home.path)
    )
    #expect(reason == .protected)
    let stale = RuleScan(
      rule: generic, items: [CleanItem(url: alias, size: 4096)], skippedCount: 0, blocked: nil)
    let report = await CleanEngine.clean(
      [stale], selected: [generic.id], preferTrash: false, environment: env, log: nil)
    #expect(report.removedCount == 0)
    #expect(fm.fileExists(atPath: support.appendingPathComponent("data").path))
  }

  @Test func extraCacheNamesAreOnlyAllowedAtRegisteredPaths() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.qoder" })
    let safety = SafetyGuard(home: home.path)
    for relative in [
      "Library/Application Support/Other/CachedData", "Library/Application Support/Qoder/User",
      "Library/Application Support/Qoder/CachedData/child",
    ] {
      #expect(
        CleanEngine.skipReason(
          for: home.appendingPathComponent(relative), rule: rule, running: [],
          environment: environment, safety: safety) == .protected)
    }
    #expect(throws: SafetyError.self) {
      try safety.validate(
        home.appendingPathComponent("Library/Application Support/Qoder/CachedData"))
    }
  }

}

private actor ApplicationLaunchFixture {
  private var reads = 0
  func names() -> Set<String> {
    reads += 1
    return reads <= 2 ? [] : ["Qoder"]
  }
}
