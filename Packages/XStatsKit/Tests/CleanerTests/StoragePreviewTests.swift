// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import SQLite3
import Testing
@testable import Cleaner

struct StoragePreviewTests {
  @Test func fixturePathContainsOnlyPhysicalDirectories() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var path = ""
    for component in root.path.split(separator: "/") {
      path += "/" + component
      var information = stat()
      try #require(lstat(path, &information) == 0)
      #expect(information.st_mode & S_IFMT == S_IFDIR)
    }
  }

  @Test func databasePreviewReadsFreePagesWithoutChangingSourceOrCreatingSidecars() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("data.db")
    try createDatabase(
      database,
      sql: """
        PRAGMA page_size=4096;
        CREATE TABLE payload(value BLOB);
        INSERT INTO payload VALUES(zeroblob(32768));
        DELETE FROM payload;
        """)
    let before = try Data(contentsOf: database)
    let observation = try StoragePreview.database(at: database, budget: budget())
    #expect(observation.mainBytes == UInt64(before.count))
    #expect(observation.freeBytes > 0)
    #expect(observation.freeBytes < observation.mainBytes)
    #expect(observation.isComplete)
    #expect(try Data(contentsOf: database) == before)
    for suffix in ["-wal", "-shm", "-journal"] {
      #expect(!FileManager.default.fileExists(atPath: database.path + suffix))
    }
  }

  @Test func quarantineCountsOnlyTheSnapshotAndNeverReturnsDownloadURLs() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("quarantine")
    try createDatabase(
      database,
      sql: """
        CREATE TABLE LSQuarantineEvent(LSQuarantineDataURLString TEXT);
        INSERT INTO LSQuarantineEvent VALUES('https://private.invalid/one');
        INSERT INTO LSQuarantineEvent VALUES('https://private.invalid/two');
        """)
    let before = try Data(contentsOf: database)
    let result = try StoragePreview.database(at: database, countQuarantine: true, budget: budget())
    #expect(result.recordCount == 2)
    #expect(result.isComplete)
    #expect(try Data(contentsOf: database) == before)
    #expect(!FileManager.default.fileExists(atPath: database.path + "-shm"))
    #expect(!FileManager.default.fileExists(atPath: database.path + "-wal"))
  }

  @Test func quarantineRejectsViewsAndAcceptsAnEmptyRealTable() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let view = root.appendingPathComponent("view.db")
    try createDatabase(
      view,
      sql: """
        CREATE TABLE payload(value TEXT);
        CREATE VIEW LSQuarantineEvent AS SELECT value FROM payload;
        """)
    let invalid = try StoragePreview.database(
      at: view, countQuarantine: true, budget: budget())
    #expect(!invalid.isComplete)
    #expect(invalid.recordCount == nil)
    let table = root.appendingPathComponent("table.db")
    try createDatabase(table, sql: "CREATE TABLE LSQuarantineEvent(value TEXT);")
    let empty = try StoragePreview.database(
      at: table, countQuarantine: true, budget: budget())
    #expect(empty.isComplete)
    #expect(empty.recordCount == 0)
  }

  @Test func walAndRollbackJournalsPreventClaimsOfCompleteDatabaseState() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("quarantine")
    try createDatabase(database, sql: "CREATE TABLE LSQuarantineEvent(value TEXT);")
    let before = try Data(contentsOf: database)
    for suffix in ["-wal", "-shm", "-journal"] {
      let sidecar = URL(fileURLWithPath: database.path + suffix)
      let content = Data(repeating: 17, count: 128)
      try content.write(to: sidecar)
      let result = try StoragePreview.database(
        at: database, countQuarantine: true, budget: budget())
      #expect(!result.isComplete)
      #expect(result.recordCount == nil)
      #expect(result.sidecarBytes == 128)
      #expect(try Data(contentsOf: sidecar) == content)
      try FileManager.default.removeItem(at: sidecar)
    }
    let emptyWAL = URL(fileURLWithPath: database.path + "-wal")
    try Data().write(to: emptyWAL)
    let result = try StoragePreview.database(
      at: database, countQuarantine: true, budget: budget())
    #expect(!result.isComplete)
    #expect(result.recordCount == nil)
    #expect(result.sidecarBytes == 0)
    #expect(try Data(contentsOf: database) == before)
  }

  @Test func walModeWithoutSidecarsStillDoesNotReadQuarantineRecords() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("quarantine")
    try createDatabase(database, sql: "CREATE TABLE LSQuarantineEvent(value TEXT);")
    var data = try Data(contentsOf: database)
    data[18] = 2
    data[19] = 2
    try data.write(to: database)
    let result = try StoragePreview.database(
      at: database, countQuarantine: true, budget: budget())
    #expect(!result.isComplete)
    #expect(result.recordCount == nil)
    #expect(!FileManager.default.fileExists(atPath: database.path + "-shm"))
  }

  @Test func corruptDatabaseAndOversizedSnapshotRemainUnknown() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("quarantine")
    try Data(repeating: 0, count: 100).write(to: database)
    #expect(throws: (any Error).self) {
      try StoragePreview.database(at: database, budget: budget())
    }
    try createDatabase(
      root.appendingPathComponent("valid"),
      sql: """
        CREATE TABLE LSQuarantineEvent(value TEXT);
        """)
    let result = try StoragePreview.database(
      at: root.appendingPathComponent("valid"), countQuarantine: true,
      snapshotLimit: 100, budget: budget())
    #expect(!result.isComplete)
    #expect(result.recordCount == nil)
  }

  @Test func symlinkAncestorsAndDatabaseSidecarsAreNeverFollowed() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try createDatabase(target.appendingPathComponent("db"), sql: "CREATE TABLE item(value TEXT);")
    // 先证明真实路径可读，避免全部读取均失败时链接拒绝测试仍然通过。
    let readable = try StoragePreview.database(
      at: target.appendingPathComponent("db"), budget: budget())
    #expect(readable.isComplete)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: (any Error).self) {
      try StoragePreview.database(at: link.appendingPathComponent("db"), budget: budget())
    }
    let database = target.appendingPathComponent("db")
    let leaf = root.appendingPathComponent("linked.db")
    try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: database)
    #expect(throws: (any Error).self) {
      try StoragePreview.database(at: leaf, budget: budget())
    }
    try FileManager.default.createSymbolicLink(
      at: URL(fileURLWithPath: database.path + "-wal"), withDestinationURL: database)
    #expect(throws: (any Error).self) {
      try StoragePreview.database(at: database, budget: budget())
    }
  }

  @Test func treeMeasurementDeduplicatesHardlinksAndDoesNotReturnPartialDirectorySizes() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("storage")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("disk.raw")
    try Data(repeating: 41, count: 8192).write(to: file)
    let oneFile = try StoragePreview.allocatedSize(of: file, budget: budget())
    try FileManager.default.linkItem(at: file, to: directory.appendingPathComponent("alias.raw"))
    #expect(try StoragePreview.allocatedSize(of: directory, budget: budget()) == oneFile)
    #expect(throws: (any Error).self) {
      try StoragePreview.allocatedSize(
        of: directory, budget: ScanBudget(limits: ScanLimits(maxEntries: 1)))
    }
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("linked"), withDestinationURL: file)
    #expect(throws: (any Error).self) {
      try StoragePreview.allocatedSize(of: directory, budget: budget())
    }
  }

  @Test func treeMeasurementIncludesHiddenFilesAndNestedModelDirectories() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let hidden = root.appendingPathComponent(".model")
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    let visibleFile = root.appendingPathComponent("disk.raw")
    let hiddenFile = hidden.appendingPathComponent(".weights")
    try Data(repeating: 1, count: 8192).write(to: visibleFile)
    try Data(repeating: 2, count: 16384).write(to: hiddenFile)
    let expected =
      try StoragePreview.allocatedSize(of: visibleFile, budget: budget())
      + StoragePreview.allocatedSize(of: hiddenFile, budget: budget())
    #expect(try StoragePreview.allocatedSize(of: root, budget: budget()) == expected)
    #expect(try StoragePreview.allocatedSize(of: hiddenFile, budget: budget()) > 0)
  }

  @Test func absentApplicationInventoryDoesNotDiscoverOrConsumeTheFileBudget() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try ownership("com.example.review", home: root)
    let result = try StoragePreview.applicationDataReview(
      home: root.path, installedIdentifiers: nil,
      budget: ScanBudget(limits: ScanLimits(maxEntries: 0)))
    #expect(result.status == .unchecked)
    #expect(!result.isComplete)
    #expect(result.evidence.isEmpty)
  }

  @Test func finiteApplicationInventoryRequiresExplicitMetadataAndAlwaysRemainsIncomplete() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = root.appendingPathComponent("Library/Preferences")
    try ownership("com.example.review", home: root)
    try ownership("com.example.installed", home: root)
    try ownership("com.example.container", home: root, container: true)
    try ownership("com.apple.protected", home: root)
    try ownership("group.com.apple.protected", home: root, container: true)
    try Data("not ownership evidence".utf8)
      .write(to: preferences.appendingPathComponent("com.example.ambiguous.plist"))
    let mismatched = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "com.example.other"], format: .binary, options: 0)
    try mismatched.write(to: preferences.appendingPathComponent("com.example.mismatch.plist"))
    let result = try StoragePreview.applicationDataReview(
      home: root.path, installedIdentifiers: ["com.example.installed"], budget: budget())
    #expect(!result.isComplete)
    #expect(result.evidence.count == 2)
    #expect(result.evidence.contains { $0.hasPrefix("com.example.review · ") })
    #expect(result.evidence.contains { $0.hasPrefix("com.example.container · ") })

    let emptyLoadedList = try StoragePreview.applicationDataReview(
      home: root.path, installedIdentifiers: [], budget: budget())
    #expect(!emptyLoadedList.isComplete)
    #expect(emptyLoadedList.evidence.contains { $0.hasPrefix("com.example.installed · ") })
  }

  @Test func applicationIdentifierVariantsProtectLoadedAppsAndTheirRelatedData() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for identifier in [
      "com.example.app", "COM.EXAMPLE.APP", "com.example.app.helper",
      "group.com.example.app", "S8EX82NJP6.com.example.app",
      "S8EX82NJP6.group.com.example.app", "com.example",
      "com.example.application",
    ] {
      try ownership(identifier, home: root, container: true)
    }
    let result = try StoragePreview.applicationDataReview(
      home: root.path, installedIdentifiers: ["com.example.app"], budget: budget())
    #expect(result.status == .optional)
    #expect(!result.isComplete)
    #expect(result.evidence.count == 1)
    #expect(result.evidence.first?.hasPrefix("com.example.application · ") == true)
    let derivedLoaded = try StoragePreview.applicationDataReview(
      home: root.path, installedIdentifiers: ["s8ex82njp6.group.com.example.app.helper"],
      budget: budget())
    #expect(!derivedLoaded.isComplete)
    #expect(derivedLoaded.evidence.count == 1)
    #expect(derivedLoaded.evidence.first?.hasPrefix("com.example.application · ") == true)
  }

  @Test func injectedFullScanUsesOnlyFixtureRootsAndPreservesSourceFiles() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("Home")
    let library = root.appendingPathComponent("SystemLibrary")
    let volume = root.appendingPathComponent("Volumes/FixtureDisk")
    let databases = [
      "Library/Messages/chat.db", "Library/Safari/History.db", "Library/Safari/TopSites.db",
      "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2",
      "Library/Group Containers/group.com.apple.usernoted/db2/db",
      "Library/Application Support/Knowledge/knowledgeC.db",
      "Library/Mail/V10/MailData/Envelope Index",
    ]
    for path in databases {
      let database = home.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
      try createDatabase(
        database,
        sql: """
          CREATE TABLE LSQuarantineEvent(LSQuarantineDataURLString TEXT);
          INSERT INTO LSQuarantineEvent VALUES('https://private.invalid/fixture');
          """)
    }
    for path in [
      "Library/Application Support/MobileSync/Backup/fixture/data",
      "Library/Containers/com.docker.docker/Data/disk.raw",
      ".lima/fixture/disk", "OrbStack/disk.raw",
      "Library/Application Support/Claude/claude-code-vm/disk",
      ".lmstudio/models/.weights", ".cache/huggingface/model/.weights",
      "Library/Group Containers/TEAM.dev.orbstack/data/disk.raw",
      "Library/iTunes/iPhone Software Updates/fixture.ipsw",
      ".DS_Store", "Desktop/.DS_Store", "Documents/.DS_Store", "Downloads/.DS_Store",
      "Library/Application Support/com.apple.sharedfilelist/list",
      "Library/Caches/com.apple.rosetta.update/cache", "Library/Updates/data",
    ] {
      try writeFixtureFile(home.appendingPathComponent(path))
    }
    for path in [
      "Caches/cache", "Updates/update",
      "Apple/usr/share/rosetta/rosetta_update_bundle/data",
    ] {
      try writeFixtureFile(library.appendingPathComponent(path))
    }
    let marker = volume.appendingPathComponent("Backups.backupdb/FixtureMac/fixture.inProgress")
    try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
    try ownership("com.example.review", home: home)
    try ownership("com.example.container", home: home, container: true)
    let before = try fixtureFiles(root)
    let findings = try await StoragePreview.scan(
      home: home.path, installedIdentifiers: ["com.docker.docker"],
      systemLibrary: library, localVolumes: { _ in [volume] }, budget: budget())
    let byID = Dictionary(uniqueKeysWithValues: findings.map { ($0.id, $0) })
    #expect(findings.first?.id == "storage.orphans")
    let applicationData = try #require(byID["storage.orphans"])
    #expect(!applicationData.isComplete)
    #expect(applicationData.evidence.contains { $0.hasPrefix("com.example.review · ") })
    #expect(applicationData.evidence.contains { $0.hasPrefix("com.example.container · ") })
    for id in [
      "messages", "safariHistory", "safariTopSites", "quarantine", "notifications",
      "coreduet", "mail.V10", "systemCaches", "rosetta", "deviceBackups",
      "virtualMachines", "aiModels", "metadata", "firmware", "orbStack",
    ] {
      let finding = try #require(byID["storage." + id])
      #expect(finding.status == .optional)
      #expect(finding.isComplete)
      #expect(!finding.evidence.isEmpty)
    }
    let backup = try #require(byID["storage.timeMachine"])
    #expect(backup.status == .unchecked)
    #expect(!backup.isComplete)
    #expect(backup.evidence == [marker.path])
    for evidence in findings.flatMap(\.evidence) {
      #expect(!evidence.contains("https://private.invalid"))
      if evidence.hasPrefix("/") {
        #expect(evidence.hasPrefix(root.path + "/"))
      }
    }
    #expect(try fixtureFiles(root) == before)
  }

  @Test func injectedScanPreservesCandidateBudgetForOwnershipAndDatabases() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("Home")
    // 系统偏好应在业务筛选时跳过，不能占满实际审阅候选的预算。
    for index in 0..<201 {
      try ownership("com.apple.fixture\(index)", home: home)
    }
    try ownership("com.example.review", home: home)
    let database = home.appendingPathComponent("Library/Messages/chat.db")
    try FileManager.default.createDirectory(
      at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
    try createDatabase(database, sql: "CREATE TABLE payload(value TEXT);")
    let before = try fixtureFiles(root)
    let scanBudget = ScanBudget(
      limits: ScanLimits(maxEntries: 20_000, maxDuration: 15, maxCandidates: 200))
    let findings = try await StoragePreview.scan(
      home: home.path, installedIdentifiers: ["com.example.installed"],
      systemLibrary: root.appendingPathComponent("SystemLibrary"),
      localVolumes: { _ in [] }, budget: scanBudget)
    let applicationData = try #require(findings.first { $0.id == "storage.orphans" })
    #expect(applicationData.status == .optional)
    #expect(!applicationData.isComplete)
    #expect(applicationData.evidence.count == 1)
    #expect(applicationData.evidence.first?.hasPrefix("com.example.review · ") == true)
    let messages = try #require(findings.first { $0.id == "storage.messages" })
    #expect(messages.status == .optional)
    #expect(messages.isComplete)
    #expect(messages.evidence.contains(database.path))
    #expect(scanBudget.interruption == nil)
    #expect(try fixtureFiles(root) == before)
  }

  @Test func applicationReviewStillEnforcesAcceptedCandidateLimit() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for identifier in ["com.example.first", "com.example.second", "com.example.third"] {
      try ownership(identifier, home: root)
    }
    let scanBudget = ScanBudget(
      limits: ScanLimits(maxEntries: 10_000, maxDuration: 15, maxCandidates: 1))
    let result = try StoragePreview.applicationDataReview(
      home: root.path, installedIdentifiers: [], budget: scanBudget)
    #expect(result.status == .unchecked)
    #expect(!result.isComplete)
    #expect(result.evidence.count == 1)
    #expect(scanBudget.interruption == .entryLimit)
  }

  @Test func ignoredPreferencesStillRespectEntryAndDeadlineLimits() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<201 {
      try ownership("com.apple.fixture\(index)", home: root)
    }
    for (limits, expected) in [
      (
        ScanLimits(maxEntries: 100, maxDuration: 15, maxCandidates: 200),
        ScanInterruption.entryLimit
      ),
      (
        ScanLimits(maxEntries: 20_000, maxDuration: 0, maxCandidates: 200),
        ScanInterruption.timeLimit
      ),
    ] {
      let scanBudget = ScanBudget(limits: limits)
      let result = try StoragePreview.applicationDataReview(
        home: root.path, installedIdentifiers: ["com.example.installed"], budget: scanBudget)
      #expect(result.status == .unchecked)
      #expect(!result.isComplete)
      #expect(result.evidence.isEmpty)
      #expect(scanBudget.interruption == expected)
    }
  }

  @Test func applicationReviewPrecedesHeavyTreesEvenWhenTheirBudgetIsExhausted() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try ownership("com.example.review", home: root)
    for index in 0..<400 {
      try writeFixtureFile(root.appendingPathComponent("SystemLibrary/Caches/\(index)"))
    }
    let findings = try await StoragePreview.scan(
      home: root.path, installedIdentifiers: [],
      systemLibrary: root.appendingPathComponent("SystemLibrary"),
      localVolumes: { _ in [] },
      budget: ScanBudget(limits: ScanLimits(maxEntries: 300, maxDuration: 5, maxCandidates: 100)))
    let applicationData = try #require(findings.first)
    #expect(applicationData.id == "storage.orphans")
    #expect(!applicationData.isComplete)
    #expect(applicationData.evidence.count == 1)
    let caches = try #require(findings.first { $0.id == "storage.systemCaches" })
    #expect(caches.status == .unchecked)
    #expect(!caches.isComplete)
  }

  @Test func cancelledScanThrowsInsteadOfPublishingUnknownResults() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await StoragePreview.scan(
        home: root.path, installedIdentifiers: nil,
        systemLibrary: root.appendingPathComponent("SystemLibrary"),
        localVolumes: { _ in
          Issue.record("A cancelled scan requested local volumes")
          return []
        }, budget: budget())
    }
    do {
      _ = try await task.value
      Issue.record("A cancelled storage review returned results")
    } catch is CancellationError {
    }
  }

  private func budget() -> ScanBudget {
    ScanBudget(limits: ScanLimits(maxEntries: 10_000, maxDuration: 5, maxCandidates: 100))
  }

  private func fixture() throws -> URL {
    // Foundation 的路径解析可能保留 /var 系统别名；夹具需物理路径才能测试逐层 no-follow。
    // 仅在创建夹具时解析临时根目录，生产读取仍拒绝所有链接祖先和叶子。
    guard let parent = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(parent) }
    let root = URL(fileURLWithPath: String(cString: parent), isDirectory: true)
      .appendingPathComponent("storage-preview-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func ownership(_ identifier: String, home: URL, container: Bool = false) throws {
    let directory = home.appendingPathComponent(
      container ? "Library/Containers/" + identifier : "Library/Preferences")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent(
      container ? ".com.apple.containermanagerd.metadata.plist" : identifier + ".plist")
    let data = try PropertyListSerialization.data(
      fromPropertyList: [container ? "MCMMetadataIdentifier" : "CFBundleIdentifier": identifier],
      format: .binary, options: 0)
    try data.write(to: source)
  }

  private func writeFixtureFile(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 17, count: 4096).write(to: url)
  }

  private func fixtureFiles(_ root: URL) throws -> [String: Data] {
    let files = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    var result: [String: Data] = [:]
    for case let file as URL in files {
      if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        result[file.path] = try Data(contentsOf: file)
      }
    }
    return result
  }

  private func createDatabase(_ url: URL, sql: String) throws {
    var database: OpaquePointer?
    let opened = sqlite3_open(url.path, &database)
    defer { sqlite3_close(database) }
    #expect(opened == SQLITE_OK)
    let handle = try #require(database)
    #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
  }
}
