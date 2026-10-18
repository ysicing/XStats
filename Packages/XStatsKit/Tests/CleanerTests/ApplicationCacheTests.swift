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
      ["Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs"]
    ),
    (
      "app.qoder", "Qoder", "com.qoder.ide",
      [
        "Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache",
        "DawnGraphiteCache", "DawnWebGPUCache",
      ]
    ),
    (
      "app.codebuddy", "CodeBuddy CN", "com.tencent.codebuddycn",
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
      try makeOld(file, file.deletingLastPathComponent())
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
    try makeOld(cache.appendingPathComponent("data"), cache)
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
    try makeOld(cache.appendingPathComponent("data"), cache)
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
        try makeOld(directory.appendingPathComponent("data"), directory)
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
      try makeOld(directory.appendingPathComponent("data"), directory)
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

  // MARK: 运行中拦截

  @Test(arguments: [
    ("com.qoder.ide", Set<String>()), ("com.qoder.ide.helper", Set<String>()),
    ("com.tencent.codebuddycn.helper", Set<String>()),
    ("com.todesktop.230313mzl4w4u92.helper", Set<String>()),
    // 标识未知时，名称（友好名、.app 目录名或可执行文件名）兜底。
    ("", Set(["Qoder"])), ("", Set(["qoder"])),
  ])
  func runningEditorsAreBlockedByIdentifierOrName(_ fixture: (String, Set<String>)) async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let ruleID =
      fixture.0.contains("tencent")
      ? "app.codebuddy"
      : fixture.0.contains("todesktop")
        ? "developer.cursor" : "app.qoder"
    let rule = try #require(RuleCatalog.rules().first { $0.id == ruleID })
    let environment = CleanEnvironment(
      home: home.path, runningBundleIdentifiers: { fixture.0.isEmpty ? [] : [fixture.0] },
      runningApplicationNames: { fixture.1 })
    let scans = await CleanEngine.scan([rule], environment: environment)
    guard case .appRunning = scans[0].blocked else {
      Issue.record("应因应用运行而拦截：\(String(describing: scans[0].blocked))")
      return
    }
  }

  @Test func genericRuleYieldsToEditorDirectoriesByIdentifierAndName() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(
      ApplicationCacheCatalog.runningOwner(
        directory: "Qoder", identifiers: ["com.qoder.ide.helper"], names: []) == "Qoder")
    #expect(
      ApplicationCacheCatalog.runningOwner(
        directory: "CodeBuddy CN", identifiers: ["com.tencent.codebuddycn"], names: []) != nil)
    #expect(
      ApplicationCacheCatalog.runningOwner(directory: "Qoder", identifiers: [], names: ["Qoder"])
        == "Qoder")
    #expect(
      ApplicationCacheCatalog.runningOwner(directory: "Qoder", identifiers: [], names: []) == nil)
  }

  // MARK: 路径与最近写入

  @Test func regularFileInPlaceOfApplicationDirectoryIsSkippedNotFailed() async throws {
    let fm = FileManager.default
    let home = try makeHome()
    defer { try? fm.removeItem(at: home) }
    let support = home.appendingPathComponent("Library/Application Support")
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    // 父级是普通文件：访问 Slack/Cache 时得到 ENOTDIR。
    try Data("x".utf8).write(to: support.appendingPathComponent("Slack"))
    // 目标本身是普通文件：不是目录，同样不能成为候选。
    try fm.createDirectory(
      at: support.appendingPathComponent("discord"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: support.appendingPathComponent("discord/Cache"))
    let rules = RuleCatalog.rules().filter { ["app.slack", "app.discord"].contains($0.id) }
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let scans = await CleanEngine.scan(rules, environment: environment)
    #expect(scans.count == 2)
    for scan in scans {
      #expect(scan.blocked == nil && scan.items.isEmpty)
    }
    #expect(
      ApplicationCacheCatalog.isMissingOrNotDirectory(
        NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))))
    #expect(
      ApplicationCacheCatalog.isMissingOrNotDirectory(
        NSError(
          domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
          userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
          ])))
    #expect(
      !ApplicationCacheCatalog.isMissingOrNotDirectory(
        NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
  }

  @Test func recentWriteInsideCacheBlocksCleanup() async throws {
    let fm = FileManager.default
    let home = try makeHome()
    defer { try? fm.removeItem(at: home) }
    let cache = home.appendingPathComponent("Library/Application Support/Slack/Cache")
    let nested = cache.appendingPathComponent("Cache_Data")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    let old = nested.appendingPathComponent("f_000001")
    let fresh = nested.appendingPathComponent("f_000002")
    try Data(repeating: 1, count: 4096).write(to: old)
    try Data(repeating: 1, count: 4096).write(to: fresh)
    // 目录自身的 mtime 很旧，只有深一层的文件刚被写入。
    try makeOld(old, nested, cache)
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.slack" })
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let recent = await CleanEngine.scan([rule], environment: environment)
    #expect(recent[0].items.isEmpty && recent[0].skippedReasons[.recentlyModified] == 1)
    try makeOld(fresh, nested, cache)
    let settled = await CleanEngine.scan([rule], environment: environment)
    try #require(settled[0].items.count == 1)
    // 扫描之后应用又写入缓存：执行前复检必须拦下。
    try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: fresh.path)
    let report = await CleanEngine.clean(
      settled, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(report.removedCount == 0 && report.skippedCount == 1)
    #expect(fm.fileExists(atPath: fresh.path))
  }

  @Test func recentWriteCheckIsBoundedByEntryCount() throws {
    let fm = FileManager.default
    let home = try makeHome()
    defer { try? fm.removeItem(at: home) }
    let cache = home.appendingPathComponent("Library/Application Support/Slack/Cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.slack" })
    // 层数超过上限的写入不会被发现：这是明确的有界取舍，而不是全量递归。
    var deep = cache
    for level in 0..<(CleanEngine.recentWriteDepthLimit + 2) {
      deep.appendPathComponent("d\(level)")
    }
    try fm.createDirectory(at: deep, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: deep.appendingPathComponent("fresh"))
    try makeOld(cache)
    var current = cache
    for level in 0..<(CleanEngine.recentWriteDepthLimit + 2) {
      current.appendPathComponent("d\(level)")
      try makeOld(current)
    }
    #expect(!CleanEngine.isRecentlyModified(cache, rule: rule, now: Date()))
  }

  // MARK: 保留根与符号链接

  @Test func genericScanFlagDrivesReservedRootsNotRuleID() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let codex = home.appendingPathComponent("Library/Caches/Codex")
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let safety = SafetyGuard(home: home.path)
    func rule(id: String, generic: Bool) -> CleanRule {
      CleanRule(
        id: id, category: .system, title: id, detail: "", symbol: "archivebox",
        isGenericLibraryScan: generic, minimumAge: 0
      ) { _ in [] }
    }
    // 新增、id 不同的通用规则也必须让出专属目录。
    #expect(
      CleanEngine.skipReason(
        for: codex, rule: rule(id: "future.caches", generic: true), running: [],
        environment: environment, safety: safety) == .protected)
    #expect(
      CleanEngine.skipReason(
        for: codex, rule: rule(id: "system.caches", generic: false), running: [],
        environment: environment, safety: safety) == nil)
    #expect(RuleCatalog.userCaches.isGenericLibraryScan && RuleCatalog.logs.isGenericLibraryScan)
  }

  @Test func safetyGuardAllowsCodexLeavesOnlyAtRegisteredPaths() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let safety = SafetyGuard(home: home.path)
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.codex" })
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let caches = home.appendingPathComponent("Library/Caches/Codex")
    // 缓存根本身不在登记路径内；用户状态目录同样拒绝。
    for relative in ["", "Default", "Default/Local Storage", "Default/Cache/child", "Other/Cache"] {
      #expect(
        CleanEngine.skipReason(
          for: caches.appendingPathComponent(relative), rule: rule, running: [],
          environment: environment, safety: safety) == .protected)
    }
    for relative in ["Default/Cache", "Default/Partitions/codex-browser-app/Code Cache"] {
      let url = caches.appendingPathComponent(relative)
      // 未重定向检查按 lstat 逐级核对，目录必须真实存在。
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try makeOld(url)
      #expect(throws: Never.self) {
        try safety.validate(url, additionalCachePaths: rule.cacheRelativePaths)
      }
      #expect(
        CleanEngine.skipReason(
          for: url, rule: rule, running: [], environment: environment, safety: safety) == nil)
    }
    // 登记路径不影响 Application Support 的其他位置。
    #expect(throws: SafetyError.self) {
      try safety.validate(
        home.appendingPathComponent("Library/Application Support/Codex/Default"),
        additionalCachePaths: rule.cacheRelativePaths)
    }
  }

  @Test(arguments: [false, true])
  func rejectsRedirectedIntermediateDirectory(afterScan: Bool) async throws {
    let fm = FileManager.default
    let home = try makeHome()
    defer { try? fm.removeItem(at: home) }
    let caches = home.appendingPathComponent("Library/Caches")
    let real = caches.appendingPathComponent("CodexReal")
    let root = caches.appendingPathComponent("Codex")
    for leaf in ["Cache", "Code Cache"] {
      let directory = real.appendingPathComponent("Default/" + leaf)
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: directory.appendingPathComponent("data"))
      try makeOld(directory.appendingPathComponent("data"), directory)
    }
    try makeOld(real, real.appendingPathComponent("Default"))
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.codex" })
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    var scans: [RuleScan] = []
    if afterScan {
      // 先以真实目录扫描，再把中间层换成符号链接。
      try fm.moveItem(at: real, to: root)
      scans = await CleanEngine.scan([rule], environment: environment)
      try #require(scans[0].items.count == 2)
      try fm.moveItem(at: root, to: real)
      try fm.createSymbolicLink(at: root, withDestinationURL: real)
      let report = await CleanEngine.clean(
        scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
      #expect(report.removedCount == 0 && report.skippedCount == 2)
    } else {
      try fm.createSymbolicLink(at: root, withDestinationURL: real)
      scans = await CleanEngine.scan([rule], environment: environment)
      #expect(scans[0].items.isEmpty && scans[0].skippedReasons[.protected] == 2)
    }
    #expect(fm.fileExists(atPath: real.appendingPathComponent("Default/Cache/data").path))
  }

  // MARK: 废纸篓与取消

  @Test func trashPathRecordsTrashedBytesAndSkipsRunningApps() async throws {
    let fm = FileManager.default
    let home = try makeHome()
    defer { try? fm.removeItem(at: home) }
    let cache = home.appendingPathComponent("Library/Application Support/Slack/Cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data"))
    try makeOld(cache.appendingPathComponent("data"), cache)
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.slack" })
    var environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let recorder = TrashRecorder()
    environment.trash = { recorder.record($0) }
    let scans = await CleanEngine.scan([rule], environment: environment)
    let size = try #require(scans[0].items.first?.size)
    var running = environment
    running.runningBundleIdentifiers = { ["com.tinyspeck.slackmacgap"] }
    let skipped = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: true, environment: running, log: nil)
    #expect(skipped.removedCount == 0 && skipped.skippedCount == 1 && recorder.urls.isEmpty)
    let report = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: true, environment: environment, log: nil)
    #expect(report.removedCount == 1 && report.trashedBytes == size && report.freedBytes == 0)
    #expect(recorder.urls.map(\.path) == [cache.path])
    // 废纸篓由替身接管：目录仍在原处，证明没有同时走永久删除。
    #expect(fm.fileExists(atPath: cache.path))
    let permanent = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: false, environment: environment, log: nil)
    #expect(permanent.freedBytes == size && permanent.trashedBytes == 0)
    #expect(!fm.fileExists(atPath: cache.path) && recorder.urls.count == 1)
  }

  @Test func trashFailureIsReportedAndDoesNotCountAsRemoved() async throws {
    let fm = FileManager.default
    let home = try makeHome()
    defer { try? fm.removeItem(at: home) }
    let cache = home.appendingPathComponent("Library/Application Support/Slack/Cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data"))
    try makeOld(cache.appendingPathComponent("data"), cache)
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.slack" })
    var environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    environment.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
    let scans = await CleanEngine.scan([rule], environment: environment)
    let report = await CleanEngine.clean(
      scans, selected: [rule.id], preferTrash: true, environment: environment, log: nil)
    #expect(report.removedCount == 0 && report.trashedBytes == 0 && report.failures.count == 1)
    #expect(fm.fileExists(atPath: cache.path))
  }

  @Test(arguments: [CancelPoint.beforeItem, CancelPoint.duringRecheck])
  func cancellationStopsDeletionBeforeTheNextItem(_ point: CancelPoint) async throws {
    let fm = FileManager.default
    let home = try makeHome()
    defer { try? fm.removeItem(at: home) }
    let cache = home.appendingPathComponent("Library/Application Support/Slack/Cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("data"))
    try makeOld(cache.appendingPathComponent("data"), cache)
    let rule = try #require(RuleCatalog.rules().first { $0.id == "app.slack" })
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let scans = await CleanEngine.scan([rule], environment: environment)
    try #require(scans[0].items.count == 1)
    var cancelling = environment
    if point == .duringRecheck {
      // skipReason 读取当前时间时取消，模拟遍历期间被用户取消。
      cancelling.now = {
        withUnsafeCurrentTask { $0?.cancel() }
        return Date()
      }
    }
    let task = Task {
      await CleanEngine.clean(
        scans, selected: [rule.id], preferTrash: false, environment: cancelling, log: nil,
        refreshRunningApps: {
          if point == .beforeItem { withUnsafeCurrentTask { $0?.cancel() } }
          return []
        })
    }
    let report = await task.value
    #expect(report.wasCancelled && report.removedCount == 0)
    #expect(fm.fileExists(atPath: cache.path))
  }

  // MARK: 夹具

  enum CancelPoint: Sendable { case beforeItem, duringRecheck }

  private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  /// 最近写入检查会遍历缓存内部，夹具必须把文件和目录的修改时间一起调旧。
  private func makeOld(_ urls: URL...) throws {
    for url in urls {
      try FileManager.default.setAttributes(
        [.modificationDate: Date.distantPast], ofItemAtPath: url.path)
    }
  }
}

private final class TrashRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [URL] = []
  var urls: [URL] { lock.withLock { recorded } }
  func record(_ url: URL) { lock.withLock { recorded.append(url) } }
}

private actor ApplicationLaunchFixture {
  private var reads = 0
  func names() -> Set<String> {
    reads += 1
    return reads <= 2 ? [] : ["Qoder"]
  }
}
