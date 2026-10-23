// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct PreviewRuleCatalogTests {
  @Test func rulesAreUnselectedReadOnlyFilePreviews() {
    let rules = PreviewRuleCatalog.rules
    #expect(rules.isEmpty == false)
    #expect(Set(rules.map(\.id)).count == rules.count)
    for rule in rules {
      #expect(rule.previewOnly)
      #expect(rule.selectedByDefault == false)
      #expect(rule.usesToolCleaner == false)
      #expect(rule.requiresUnredirectedPath)
      #expect(rule.cacheRelativePaths.isEmpty == false)
    }
  }

  @Test func teamsMatchesOnlyTheSourceVerifiedCacheDirectory() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let cache = try fixture.file("Library/Caches/com.microsoft.teams2/data")
      .deletingLastPathComponent()
    let preserved = [
      "Library/Caches/com.microsoft.teams2.other/data",
      "Library/Application Support/Microsoft/Teams/Cache/data",
      "Library/Containers/com.microsoft.teams2/Data/Library/Caches/WebKit/NetworkCache/data",
      "Library/Containers/com.microsoft.teams2/Data/Library/Caches/com.microsoft.teams2/WebKit/NetworkCache/data",
      "Library/Containers/com.microsoft.teams2/Data/Documents/document",
    ]
    for path in preserved { _ = try fixture.file(path) }

    let rule = try #require(PreviewRuleCatalog.rules.first { $0.id == "preview.teams" })
    #expect(rule.cacheRelativePaths == ["Library/Caches/com.microsoft.teams2"])
    #expect(try rule.locate(fixture.environment) == [cache])
    try SafetyGuard(home: fixture.root.path).validate(cache)
    let container = fixture.root.appendingPathComponent(
      "Library/Containers/com.microsoft.teams2/Data/Library/Caches/WebKit/NetworkCache")
    #expect(throws: SafetyError.outsideAllowedRoots) {
      try SafetyGuard(home: fixture.root.path).validate(container)
    }
  }

  @Test(arguments: [false, true])
  func selectedTeamsPreviewCannotRemoveFixtureFiles(preferTrash: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let file = try fixture.file("Library/Caches/com.microsoft.teams2/data")
    let rule = try #require(PreviewRuleCatalog.rules.first { $0.id == "preview.teams" })
    let scan = try #require(
      await CleanEngine.scan([rule], environment: fixture.environment).first)
    #expect(scan.items.map(\.url) == [file.deletingLastPathComponent()])
    #expect(scan.totalSize > 0)
    #expect(scan.isComplete)
    #expect(scan.isCleanable == false)

    let report = await CleanEngine.clean(
      [scan], selected: [rule.id], preferTrash: preferTrash,
      environment: fixture.environment, log: nil)
    #expect(report.removedCount == 0)
    #expect(try Data(contentsOf: file) == Data(repeating: 1, count: 4096))
  }

  @Test(arguments: [
    ("com.microsoft.teams2", ""),
    ("com.microsoft.teams2.helper", ""),
    ("", "Microsoft Teams"),
    ("", "microsoft teams"),
  ])
  func teamsRunningApplicationBlocksPreview(_ running: (String, String)) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.file("Library/Caches/com.microsoft.teams2/data")
    let rule = try #require(PreviewRuleCatalog.rules.first { $0.id == "preview.teams" })
    var environment = fixture.environment
    environment.runningBundleIdentifiers = { running.0.isEmpty ? [] : [running.0] }
    environment.runningApplicationNames = { running.1.isEmpty ? [] : [running.1] }

    let scan = try #require(await CleanEngine.scan([rule], environment: environment).first)
    #expect(scan.blocked == .appRunning("Microsoft Teams"))
    #expect(scan.items.isEmpty)
    #expect(rule.runningApplication(identifiers: ["com.microsoft.teams20"], names: []) == nil)
  }

  @Test func missingCacheAndRegularFileAreNotDirectoryCandidates() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let rule = try #require(PreviewRuleCatalog.rules.first { $0.id == "preview.teams" })
    #expect(try rule.locate(fixture.environment).isEmpty)
    _ = try fixture.file("Library/Caches/com.microsoft.teams2")
    #expect(try rule.locate(fixture.environment).isEmpty)
  }

  @Test func redirectedTeamsCacheIsNotMeasured() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let file = try fixture.file("Library/Caches/other/data")
    let link = fixture.root.appendingPathComponent("Library/Caches/com.microsoft.teams2")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: file.deletingLastPathComponent())
    let rule = try #require(PreviewRuleCatalog.rules.first { $0.id == "preview.teams" })
    let scan = try #require(
      await CleanEngine.scan([rule], environment: fixture.environment).first)
    #expect(scan.items.isEmpty)
    #expect(scan.totalSize == 0)
    #expect(try Data(contentsOf: file) == Data(repeating: 1, count: 4096))
  }

  @Test func genericCacheScanDoesNotDuplicateTeamsPreview() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let cache = try fixture.file("Library/Caches/com.microsoft.teams2/data")
      .deletingLastPathComponent()
    let rule = try #require(PreviewRuleCatalog.rules.first { $0.id == "preview.teams" })
    let scans = await CleanEngine.scan(
      [RuleCatalog.userCaches, rule], environment: fixture.environment)
    let generic = try #require(scans.first { $0.id == RuleCatalog.userCaches.id })
    let preview = try #require(scans.first { $0.id == rule.id })
    #expect(generic.items.isEmpty)
    #expect(preview.items.map(\.url) == [cache])
    #expect(preview.isCleanable == false)
  }

  private struct Fixture {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PreviewRuleCatalogTests-" + UUID().uuidString)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var environment: CleanEnvironment {
      CleanEnvironment(
        home: root.path, runningBundleIdentifiers: { [] },
        now: { Date(timeIntervalSince1970: 2_000_000_000) },
        isToolAvailable: { _ in false }, toolEnvironment: [:])
    }

    func file(_ path: String) throws -> URL {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4096).write(to: url)
      for item in [url, url.deletingLastPathComponent()] {
        try FileManager.default.setAttributes(
          [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
          ofItemAtPath: item.path)
      }
      return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
