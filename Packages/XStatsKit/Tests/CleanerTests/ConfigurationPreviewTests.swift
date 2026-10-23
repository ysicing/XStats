// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreServices
import Foundation
import Testing
@testable import Cleaner

struct ConfigurationPreviewTests {
  @Test func protectedPreferencesDoNotConsumeTheReviewCandidateBudget() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for index in 0..<501 {
      _ = try fixture.file(
        "Library/Preferences/com.apple.fixture\(index).plist", Data("{".utf8))
      _ = try fixture.file("Applications/ignored\(index).txt", Data())
    }
    _ = try fixture.plist(
      "Library/Preferences/com.apple.spotlight.plist",
      ["EnabledPreferenceRules": ["org.example.review"]])
    _ = try fixture.plist(
      "Applications/Review.app/Contents/Info.plist", ["CFBundleIdentifier": "org.example.review"])
    let target = try fixture.file(
      "Library/Preferences/org.example.review.plist", Data("{".utf8))
    let shared = try fixture.plist(
      "Library/Application Support/com.apple.sharedfilelist/favorites.sfl3",
      ["$archiver": "NSKeyedArchiver", "$objects": ["$null"]])
    let snapshots = try [target, shared].map { try Data(contentsOf: $0) }
    let findings = try await fixture.scan()
    let preferences = try finding("preferencePlists", in: findings)
    #expect(preferences.status == .attention && preferences.isComplete)
    #expect(preferences.evidence.contains { $0.hasSuffix("org.example.review.plist") })
    let lists = try finding("sharedFileLists", in: findings)
    #expect(lists.status == .normal && lists.isComplete)
    #expect(try finding("finderMetadata", in: findings).isComplete)
    #expect(try finding("spotlightRules", in: findings).isComplete)
    #expect(try [target, shared].map { try Data(contentsOf: $0) } == snapshots)
  }

  @Test func acceptedPreferencesStillConsumeTheCandidateBudget() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for index in 0..<3 {
      _ = try fixture.plist(
        "Library/Preferences/org.example.fixture\(index).plist", ["enabled": true])
    }
    var environment = fixture.environment()
    environment.scanLimits = ScanLimits(maxEntries: 2_000, maxDuration: 20, maxCandidates: 2)
    let findings = try await fixture.scan(environment: environment)
    #expect(try !finding("preferencePlists", in: findings).isComplete)
    #expect(try !finding("finderMetadata", in: findings).isComplete)
  }

  @Test func protectedPreferencesStillConsumeTheEntryBudget() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for index in 0..<21 {
      _ = try fixture.file(
        "Library/Preferences/com.apple.fixture\(index).plist", Data("{".utf8))
    }
    var environment = fixture.environment()
    environment.scanLimits = ScanLimits(maxEntries: 20, maxDuration: 20, maxCandidates: 500)
    let findings = try await fixture.scan(environment: environment)
    #expect(try !finding("preferencePlists", in: findings).isComplete)
    #expect(try !finding("finderMetadata", in: findings).isComplete)
  }

  @Test func savedStateCountsOnlyEligibleDirectoriesAndStillEnforcesTheirLimit() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    for index in 0..<501 {
      _ = try fixture.file("Library/Saved Application State/ignored\(index).txt", Data())
    }
    _ = try fixture.state("org.example.first.savedState", age: 31 * 86_400)
    var environment = fixture.environment()
    environment.scanLimits = ScanLimits(maxEntries: 2_000, maxDuration: 20, maxCandidates: 1)
    let first = try await ConfigurationPreview.savedState(environment: environment)
    #expect(first.isComplete && first.evidence.count == 1)
    _ = try fixture.state("org.example.second.savedState", age: 31 * 86_400)
    let limited = try await ConfigurationPreview.savedState(environment: environment)
    #expect(!limited.isComplete)
    #expect(limited.evidence.count == 1)
  }

  @Test func plistChecksProtectSystemPreferencesAndRecentDocuments() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let valid = try fixture.plist("Library/Preferences/org.example.good.plist", ["enabled": true])
    let array = try fixture.plist("Library/Preferences/ByHost/org.example.array.plist", ["a", "b"])
    let scalar = try fixture.file(
      "Library/Preferences/org.example.scalar.plist", Data("unquoted".utf8))
    // 单个单词是合法的 OpenStep 字符串；未闭合字典才是格式损坏。
    let malformed = Data("{".utf8)
    let broken = try fixture.file("Library/Preferences/org.example.broken.plist", malformed)
    for name in ["com.apple.protected.plist", ".GlobalPreferences.plist", "loginwindow.plist"] {
      _ = try fixture.file("Library/Preferences/" + name, malformed)
    }
    _ = try fixture.file(
      "Library/Preferences/Nested/org.example.nested.plist", malformed)
    let shared = try fixture.plist(
      "Library/Application Support/com.apple.sharedfilelist/favorites.sfl3",
      ["$archiver": "NSKeyedArchiver", "$objects": ["$null", ["bookmark": Data([1, 2, 3])]]])
    let recent = try fixture.file(
      "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments.sfl4",
      malformed)
    let snapshots = try [valid, array, scalar, broken, shared, recent].map {
      try Data(contentsOf: $0)
    }
    let findings = try await fixture.scan()
    let preferences = try finding("preferencePlists", in: findings)
    #expect(preferences.status == .attention)
    #expect(preferences.isComplete)
    #expect(preferences.evidence.count == 2)
    #expect(preferences.evidence.contains { $0.hasSuffix("org.example.broken.plist") })
    #expect(!preferences.evidence.contains { $0.contains("protected") || $0.contains("nested") })
    let lists = try finding("sharedFileLists", in: findings)
    #expect(lists.status == .normal)
    #expect(lists.isComplete)
    #expect(!lists.evidence.contains { $0.contains("ApplicationRecentDocuments") })
    #expect(
      try [valid, array, scalar, broken, shared, recent].map { try Data(contentsOf: $0) }
        == snapshots)
  }

  @Test func largeFilesLinksAndExcludedPathsAreUnknownRatherThanCorrupt() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let target = try fixture.plist("outside.plist", ["private": true])
    let oversized = try fixture.file(
      "Library/Preferences/org.example.large.plist", Data(repeating: 32, count: 1_048_577))
    let link = fixture.root.appendingPathComponent("Library/Preferences/org.example.link.plist")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let excluded = try fixture.file(
      "Library/Preferences/org.example.excluded.plist", Data("not inspected".utf8))
    var environment = fixture.environment()
    environment.excludedPaths = [excluded.path]
    let findings = try await fixture.scan(environment: environment)
    let preferences = try finding("preferencePlists", in: findings)
    #expect(preferences.status == .unchecked)
    #expect(!preferences.isComplete)
    #expect(preferences.evidence.count == 1)
    #expect(try Data(contentsOf: oversized).count == 1_048_577)
    #expect(try SystemCheck.readPropertyList(target)["private"] as? Bool == true)
  }

  @Test func linkedPreferenceParentIsNotRead() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let outside = fixture.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: outside.appendingPathComponent("org.example.private.plist"))
    let library = fixture.root.appendingPathComponent("Library")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: library.appendingPathComponent("Preferences"), withDestinationURL: outside)
    let findings = try await fixture.scan()
    let preferences = try finding("preferencePlists", in: findings)
    #expect(preferences.status == .unchecked)
    #expect(!preferences.evidence.contains { $0.contains("private") })
  }

  @Test func sharedListSubdirectoriesAreLimitedAndNeverUnarchived() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.file(
      "Library/Application Support/com.apple.sharedfilelist/Nested/favorite.sfl2", Data("{".utf8))
    _ = try fixture.file(
      "Library/Application Support/com.apple.sharedfilelist/invalid.sfl4", Data("{".utf8))
    let findings = try await fixture.scan()
    let lists = try finding("sharedFileLists", in: findings)
    #expect(lists.status == .attention)
    #expect(!lists.isComplete)
    #expect(lists.evidence.contains { $0.hasSuffix("invalid.sfl4") })
    #expect(!lists.evidence.contains { $0.contains("Nested") })
  }

  @Test func finderPreferencesAreOptionalAndRequireBooleanTypes() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let absent = try await fixture.scan()
    #expect(try finding("finderMetadata", in: absent).status == .optional)
    _ = try fixture.plist(
      "Library/Preferences/com.apple.desktopservices.plist",
      [
        "DSDontWriteNetworkStores": false, "DSDontWriteUSBStores": true,
      ])
    let present = try await fixture.scan()
    let preference = try finding("finderMetadata", in: present)
    #expect(preference.status == .optional)
    #expect(preference.isComplete)
    #expect(preference.evidence.contains("DSDontWriteUSBStores = true"))
    _ = try fixture.plist(
      "Library/Preferences/com.apple.desktopservices.plist",
      [
        "DSDontWriteNetworkStores": "YES", "DSDontWriteUSBStores": 1,
      ])
    let unknown = try await fixture.scan()
    #expect(try finding("finderMetadata", in: unknown).status == .unchecked)
  }

  @Test func spotlightDisabledSkipsQueryAndEmptyResultsDoNotProveHealth() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let disabledCalls = Calls()
    let disabled = fixture.environment { tool, arguments in
      await disabledCalls.record(tool, arguments)
      if tool == "mdutil" { return ToolRunResult(status: 0, output: "/:\n Indexing disabled.\n") }
      throw FakeError.unexpectedCommand
    }
    let disabledFindings = try await fixture.scan(environment: disabled)
    #expect(try finding("spotlightIndex", in: disabledFindings).status == .notApplicable)
    #expect(await disabledCalls.tools() == ["mdutil"])

    let emptyCalls = Calls()
    let empty = fixture.environment { tool, arguments in
      await emptyCalls.record(tool, arguments)
      return ToolRunResult(status: 0, output: tool == "mdutil" ? "/:\n Indexing enabled.\n" : "0\n")
    }
    let emptyFindings = try await fixture.scan(environment: empty)
    let index = try finding("spotlightIndex", in: emptyFindings)
    #expect(index.status == .optional)
    #expect(index.isComplete)
    let calls = await emptyCalls.snapshot()
    #expect(
      calls.contains {
        $0.0 == "mdfind"
          && $0.1 == [
            "-onlyin", fixture.applications.path, "-count",
            "kMDItemContentType == 'com.apple.application-bundle'",
          ]
      })
  }

  @Test(arguments: ["Indexing enabled.\n", "unrecognized", "0\nIndexing enabled.\n"])
  func spotlightUnexpectedOrTruncatedOutputIsUnknown(_ output: String) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let environment = fixture.environment { tool, _ in
      if tool == "mdutil" { return ToolRunResult(status: 0, output: output) }
      return ToolRunResult(status: 0, output: String(repeating: "0", count: 8192))
    }
    let findings = try await fixture.scan(environment: environment)
    let index = try finding("spotlightIndex", in: findings)
    #expect(index.status == .unchecked)
    #expect(!index.isComplete)
  }

  @Test func spotlightRulesResolveRealBundlesButDoNotInventOrphans() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.plist(
      "Library/Preferences/com.apple.spotlight.plist",
      [
        "EnabledPreferenceRules": [
          "System.iphoneApps", "com.apple.mail", "org.example.present", "org.example.missing",
        ]
      ])
    _ = try fixture.plist(
      "Applications/Vendor/Present.app/Contents/Info.plist",
      [
        "CFBundleIdentifier": "org.example.present"
      ])
    let findings = try await fixture.scan()
    let rules = try finding("spotlightRules", in: findings)
    #expect(rules.status == .optional)
    #expect(!rules.isComplete)
    #expect(rules.evidence.count == 2)
    #expect(rules.evidence.contains { $0.hasPrefix("org.example.present") })
    #expect(rules.evidence.contains { $0.hasPrefix("org.example.missing") })
    #expect(!rules.evidence.contains { $0.hasPrefix("com.apple.") || $0.hasPrefix("System.") })
  }

  @Test func spotlightRulesRejectUnknownSchemaAndUnsafeIdentifiers() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let invalidRules: [Any] = [["org.example.ok", 1], ["bad id with ' query"], "not an array"]
    for rules in invalidRules {
      _ = try fixture.plist(
        "Library/Preferences/com.apple.spotlight.plist",
        [
          "EnabledPreferenceRules": rules
        ])
      let findings = try await fixture.scan()
      let result = try finding("spotlightRules", in: findings)
      #expect(result.status == .unchecked)
      #expect(!result.isComplete)
    }
  }

  @Test func periodicUsesOnlyMetadataAndMissingToolsAreNotApplicable() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let calls = Calls()
    let now = fixture.now.timeIntervalSince1970
    var environment = fixture.environment { tool, arguments in
      await calls.record(tool, arguments)
      if tool == "stat" {
        return ToolRunResult(status: 0, output: "Regular File:\(Int(now - 100))\n")
      }
      throw FakeError.unexpectedCommand
    }
    environment.isToolAvailable = { ["periodic", "stat"].contains($0) }
    let findings = try await fixture.scan(environment: environment)
    #expect(try finding("periodicRecords", in: findings).status == .normal)
    let snapshots = await calls.snapshot()
    #expect(snapshots.count == 3)
    #expect(snapshots.allSatisfy { $0.0 == "stat" && $0.1.starts(with: ["-f", "%HT:%m"]) })
    #expect(!snapshots.contains { $0.0 == "periodic" })
    environment.isToolAvailable = { _ in false }
    let unsupported = try await fixture.scan(environment: environment)
    #expect(try finding("periodicRecords", in: unsupported).status == .notApplicable)
  }

  @Test(arguments: ["missing", "symlink", "future", "stale"])
  func periodicUnknownAndOldRecordsHaveDifferentSemantics(_ scenario: String) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let now = Int(fixture.now.timeIntervalSince1970)
    var environment = fixture.environment { _, _ in
      switch scenario {
      case "missing": return ToolRunResult(status: 1, output: "not found")
      case "symlink": return ToolRunResult(status: 0, output: "Symbolic Link:\(now)")
      case "future": return ToolRunResult(status: 0, output: "Regular File:\(now + 1)")
      default: return ToolRunResult(status: 0, output: "Regular File:\(now - 8 * 86_400)")
      }
    }
    environment.isToolAvailable = { ["periodic", "stat"].contains($0) }
    let findings = try await fixture.scan(environment: environment)
    let result = try finding("periodicRecords", in: findings)
    #expect(result.status == (scenario == "stale" ? .optional : .unchecked))
    #expect(result.isComplete == (scenario == "stale"))
  }

  @Test func loginItemsHaveAnIndependentSourceAndLocalMissingTargetsAreOnlyHints() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.plist(
      "Library/LaunchAgents/org.example.agent.plist",
      [
        "Label": "NotALoginItem", "Program": "/missing/agent",
      ])
    let app = fixture.applications.appendingPathComponent("Present.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    var sources = fixture.sources()
    sources.loginItems = { _ in
      [
        .init(name: "Present", path: app.path),
        .init(name: "Moved", path: fixture.applications.appendingPathComponent("Moved.app").path),
        .init(name: "External", path: "/Volumes/NotMounted/Example.app"),
        .init(name: "Relative", path: "Example.app"),
      ]
    }
    let findings = try await fixture.scan(sources: sources)
    let login = try finding("loginItems", in: findings)
    #expect(login.status == .attention)
    #expect(!login.isComplete)
    #expect(login.evidence.count == 4)
    #expect(!login.evidence.contains { $0.contains("NotALoginItem") })
    #expect(!login.evidence.contains { $0.contains("/Volumes/") || $0.contains(fixture.root.path) })
  }

  @Test func unavailableLoginSourceIsNotAnEmptyHealthyList() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var sources = fixture.sources()
    sources.loginItems = { _ in throw FakeError.denied }
    let unavailable = try await fixture.scan(sources: sources)
    let unknown = try finding("loginItems", in: unavailable)
    #expect(unknown.status == .unchecked)
    #expect(!unknown.isComplete)
    sources.loginItems = { _ in [] }
    let empty = try await fixture.scan(sources: sources)
    let partial = try finding("loginItems", in: empty)
    #expect(partial.status == .optional)
    #expect(!partial.isComplete)
  }

  @Test func nativeLoginSnapshotRequiresACompleteTypedList() throws {
    let reply = NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer),
      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    let list = NSAppleEventDescriptor.list()
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(NSAppleEventDescriptor(string: "Fixture"), forKeyword: 0x706e_616d)
    record.setDescriptor(
      NSAppleEventDescriptor(string: "/Applications/Fixture.app"), forKeyword: 0x7070_7468)
    list.insert(record, at: 1)
    reply.setParam(list, forKeyword: AEKeyword(keyDirectObject))
    let parsed = try ConfigurationPreview.loginItemSnapshot(reply)
    #expect(parsed.count == 1)
    #expect(parsed.first?.path == "/Applications/Fixture.app")
    record.setDescriptor(NSAppleEventDescriptor(string: "bad\nname"), forKeyword: 0x706e_616d)
    let malformed = NSAppleEventDescriptor.list()
    malformed.insert(record, at: 1)
    reply.setParam(malformed, forKeyword: AEKeyword(keyDirectObject))
    #expect(throws: (any Error).self) { try ConfigurationPreview.loginItemSnapshot(reply) }
    reply.setParam(NSAppleEventDescriptor(int32: -1743), forKeyword: AEKeyword(keyErrorNumber))
    #expect(throws: (any Error).self) { try ConfigurationPreview.loginItemSnapshot(reply) }
  }

  @Test func exhaustedBudgetPreventsToolsAndDoesNotReportNormal() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var environment = fixture.environment { _, _ in
      Issue.record("No executor should run after the budget is exhausted")
      throw FakeError.unexpectedCommand
    }
    environment.scanLimits = ScanLimits(maxEntries: 0, maxDuration: 0, maxCandidates: 0)
    let findings = try await fixture.scan(environment: environment)
    #expect(
      findings.filter { $0.id != "periodicRecords" }.allSatisfy {
        $0.status == .unchecked && !$0.isComplete
      })
  }

  @Test func failuresAndCancellationDoNotBecomeHealthyFindings() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let failed = fixture.environment { tool, _ in throw ToolExecutionError.timedOut(tool) }
    let findings = try await fixture.scan(environment: failed)
    #expect(try finding("spotlightIndex", in: findings).status == .unchecked)
    let cancelled = fixture.environment { _, _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) {
      try await fixture.scan(environment: cancelled)
    }
  }

  @Test func savedStateOnlyMeasuresOldDirectDirectoriesAndPreservesContents() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let old = try fixture.state("org.example.old.savedState", age: 31 * 86_400)
    _ = try fixture.state("org.example.recent.savedState", age: 29 * 86_400)
    _ = try fixture.state("org.example.boundary.savedState", age: 30 * 86_400)
    _ = try fixture.state("Nested/org.example.nested.savedState", age: 31 * 86_400)
    _ = try fixture.file(
      "Library/Saved Application State/org.example.file.savedState", Data("file".utf8))
    let content = try Data(contentsOf: old.appendingPathComponent("state.bin"))
    let result = try await ConfigurationPreview.savedState(environment: fixture.environment())
    #expect(result.status == .optional)
    #expect(result.isComplete)
    #expect(result.evidence.count == 1)
    #expect(result.evidence.first?.hasPrefix("org.example.old.savedState · ") == true)
    #expect(try Data(contentsOf: old.appendingPathComponent("state.bin")) == content)
  }

  @Test func savedStateProtectsBundleHelpersAndApplicationNames() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.state("org.example.running.savedState", age: 31 * 86_400)
    _ = try fixture.state("com.microsoft.teams2.savedState", age: 31 * 86_400)
    _ = try fixture.state("org.example.Friendly.savedState", age: 31 * 86_400)
    var environment = fixture.environment()
    environment.runningBundleIdentifiers = { ["org.example.running.helper"] }
    environment.runningApplicationNames = { ["microsoft teams", "friendly"] }
    let result = try await ConfigurationPreview.savedState(environment: environment)
    #expect(result.status == .optional)
    #expect(result.evidence.count == 3)
    #expect(result.evidence.allSatisfy { !$0.hasSuffix(" B") })
  }

  @Test func savedStateDoesNotFollowLinksAndDoesNotPublishPartialSize() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let old = try fixture.state("org.example.old.savedState", age: 31 * 86_400)
    let linked = old.deletingLastPathComponent().appendingPathComponent(
      "org.example.link.savedState")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: old)
    var environment = fixture.environment()
    environment.scanLimits = ScanLimits(maxEntries: 2, maxDuration: 5)
    let limited = try await ConfigurationPreview.savedState(environment: environment)
    #expect(!limited.isComplete)
    #expect(limited.evidence.isEmpty)
    let unrestricted = try await ConfigurationPreview.savedState(environment: fixture.environment())
    #expect(!unrestricted.isComplete)
    #expect(!unrestricted.evidence.contains { $0.contains("org.example.link") })
  }

  private func finding(_ id: String, in findings: [SystemCheckFinding]) throws -> SystemCheckFinding
  {
    try #require(findings.first { $0.id == id })
  }

  private enum FakeError: Error { case unexpectedCommand, denied }

  private actor Calls {
    var values: [(String, [String])] = []
    func record(_ tool: String, _ arguments: [String]) { values.append((tool, arguments)) }
    func snapshot() -> [(String, [String])] { values }
    func tools() -> [String] { values.map(\.0) }
  }

  private struct Fixture: Sendable {
    let root: URL
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var applications: URL { root.appendingPathComponent("Applications") }

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Applications"), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func file(_ path: String, _ data: Data) throws -> URL {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
      return url
    }

    func plist(_ path: String, _ value: Any) throws -> URL {
      try file(
        path,
        PropertyListSerialization.data(
          fromPropertyList: value, format: .binary, options: 0))
    }

    func state(_ name: String, age: TimeInterval) throws -> URL {
      let url = root.appendingPathComponent("Library/Saved Application State/" + name)
      _ = try file(
        "Library/Saved Application State/" + name + "/state.bin",
        Data(repeating: 0x41, count: 4_096))
      try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
      return url
    }

    func environment(
      runTool: @escaping @Sendable (String, [String]) async throws -> ToolRunResult = { tool, _ in
        if tool == "mdutil" { return ToolRunResult(status: 0, output: "/:\n Indexing enabled.\n") }
        if tool == "mdfind" { return ToolRunResult(status: 0, output: "0\n") }
        throw FakeError.unexpectedCommand
      }
    ) -> CleanEnvironment {
      CleanEnvironment(
        home: root.path, runningBundleIdentifiers: { [] }, now: { self.now },
        isToolAvailable: { ["mdutil", "mdfind"].contains($0) }, runTool: runTool,
        runToolWithEnvironment: { _, _, _ in
          Issue.record("Configuration preview must use inspectTool")
          throw FakeError.unexpectedCommand
        })
    }

    func sources() -> ConfigurationPreview.Sources {
      var sources = ConfigurationPreview.Sources(home: root.path)
      sources.applicationDirectories = [applications]
      sources.periodicLogs = ["daily.out", "weekly.out", "monthly.out"].map {
        root.appendingPathComponent("logs/" + $0).path
      }
      sources.loginItems = { _ in [] }
      return sources
    }

    func scan(
      environment: CleanEnvironment? = nil, sources: ConfigurationPreview.Sources? = nil
    ) async throws -> [SystemCheckFinding] {
      try await ConfigurationPreview.scan(
        environment: environment ?? self.environment(), sources: sources ?? self.sources())
    }
  }
}
