// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import os
import Testing
@testable import XStatsUI

private actor Shards: ActivitySyncRepository {
  let key: SymmetricKey
  var files: [[String]: Data] = [:]
  var writes = 0
  var reads = 0
  var markerCreateAttempts = 0
  var concurrentCreation = false

  init(key: SymmetricKey) { self.key = key }

  func list(_ path: [String]) -> Set<String> {
    Set(
      files.keys.compactMap { key in
        key.count > path.count && key.starts(with: path) ? key[path.count] : nil
      })
  }

  func read(_ path: [String]) -> Data? {
    if path.count == 3 { reads += 1 }
    return files[path]
  }

  func create(_ data: Data, at path: [String]) throws -> Bool {
    if path == [ActivitySyncRemotePath.marker] { markerCreateAttempts += 1 }
    guard files[path] == nil else { return false }
    if path.count == 3 {
      writes += 1
      if concurrentCreation {
        concurrentCreation = false
        let cipher = try fixtureCipher()
        let winner = try cipher.seal(cipher.open(data, at: path), at: path)
        #expect(winner != data)
        files[path] = winner
        return false
      }
    }
    files[path] = data
    return true
  }

  func simulateConcurrentCreation() { concurrentCreation = true }

  func fixtureCipher() throws -> ActivitySyncCipher {
    let cipher = ActivitySyncCipher(key: key)
    let path = [ActivitySyncRemotePath.marker]
    if let marker = files[path] {
      try cipher.authenticateMarker(marker)
    } else {
      files[path] = try cipher.makeMarker()
    }
    return cipher
  }

  func seed(_ sessions: [ActivitySession]) throws -> [String] {
    let first = try #require(sessions.first)
    let data = try ActivitySyncShard.encode(sessions)
    let shard = ActivitySyncShard(
      day: ActivitySyncShard.day(of: first.start), device: first.deviceID,
      digest: ActivitySyncShard.checksum(data))
    let cipher = try fixtureCipher()
    let path = try cipher.path(for: shard)
    files[path] = try cipher.seal(data, at: path)
    return path
  }
}

struct ActivitySyncTests {
  @Test func sharedKeychainFailureDoesNotModifyAnEmptyRepository() async throws {
    let keychain = ActivitySharedKeys(
      read: { _ in throw ActivityKeys.Failure.unavailable },
      insert: { _, _ in throw ActivityKeys.Failure.unavailable })
    let repository = Shards(key: key)
    let engine = ActivitySyncEngine(key: key, sharedKeys: keychain)
    await #expect(throws: ActivityKeys.Failure.unavailable) {
      try await engine.run(
        store: ActivityStore(url: nil), device: UUID(), repository: repository, now: now)
    }
    #expect(await repository.files.isEmpty)
    #expect(await engine.authenticatedKey == nil)
  }

  @Test func authenticatedDatasetCannotSwitchToAnotherSharedKey() async throws {
    let otherKey = SymmetricKey(size: .bits256)
    let keychain = ActivitySharedKeys(
      read: { _ in otherKey },
      insert: { _, key in key })
    let repository = Shards(key: key)
    let store = ActivityStore(url: nil)
    let device = UUID()
    _ = try await repository.fixtureCipher()
    let engine = ActivitySyncEngine(key: key, sharedKeys: keychain)
    try await engine.run(store: store, device: device, repository: repository, now: now)
    let replacement = Shards(key: otherKey)
    _ = try await replacement.fixtureCipher()
    let before = await replacement.files
    await #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try await engine.run(store: store, device: device, repository: replacement, now: now)
    }
    #expect(await replacement.files == before)
    #expect(await engine.authenticatedKey == key)
  }

  @Test func secondMacWaitsForTheAuthenticatedLegacyKeyThenJoinsAutomatically() async throws {
    let shared = OSAllocatedUnfairLock(initialState: [String: SymmetricKey]())
    let keychain = ActivitySharedKeys(
      read: { account in shared.withLock { $0[account] } },
      insert: { account, candidate in
        shared.withLock { items in
          if let existing = items[account] { return existing }
          items[account] = candidate
          return candidate
        }
      })
    let source = ActivityStore(url: nil)
    let destination = ActivityStore(url: nil)
    let sourceDevice = UUID()
    let secondDevice = UUID()
    let row = session(sourceDevice, offset: 0)
    try await source.insert([row])
    let repository = Shards(key: key)
    try await ActivitySyncEngine(key: key).run(
      store: source, device: sourceDevice, repository: repository, now: now)
    let originalFiles = await repository.files
    let second = ActivitySyncEngine(key: SymmetricKey(size: .bits256), sharedKeys: keychain)
    await #expect(throws: ActivitySyncFailure.keyPending) {
      try await second.run(
        store: destination, device: secondDevice, repository: repository, now: now)
    }
    #expect(await repository.files == originalFiles)
    #expect(shared.withLock { $0.isEmpty })
    let upgraded = ActivitySyncEngine(key: key, sharedKeys: keychain)
    try await upgraded.run(store: source, device: sourceDevice, repository: repository, now: now)
    try await second.run(store: destination, device: secondDevice, repository: repository, now: now)
    #expect(try await destination.sessions(in: DateInterval(start: now, duration: 60)) == [row])
    #expect(await second.authenticatedKey == key)
    #expect(await repository.files == originalFiles)
  }

  @Test func newMacsUseTheSharedKeyForIndependentEmptyFolders() async throws {
    let accountKey = SymmetricKey(size: .bits256)
    let keychain = ActivitySharedKeys(
      read: { account in account == "default" ? accountKey : nil },
      insert: { _, key in key })
    for _ in 0..<2 {
      let local = SymmetricKey(size: .bits256)
      let engine = ActivitySyncEngine(key: local, sharedKeys: keychain)
      let repository = Shards(key: accountKey)
      try await engine.run(
        store: ActivityStore(url: nil), device: UUID(), repository: repository, now: now)
      let bytes = try #require(await repository.read([ActivitySyncRemotePath.marker]))
      try ActivitySyncCipher(key: accountKey).authenticateMarker(bytes)
      #expect(throws: ActivitySyncFailure.self) {
        try ActivitySyncCipher(key: local).authenticateMarker(bytes)
      }
    }
  }

  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private let key = SymmetricKey(size: .bits256)
  private func session(_ device: UUID, offset: Int) -> ActivitySession {
    let start = now.addingTimeInterval(Double(offset))
    return ActivitySession(
      id: UUID(), deviceID: device, appID: "app", appName: "App",
      category: "work", start: start, end: start.addingTimeInterval(1))
  }

  @Test func twoSQLiteDevicesRoundTripThroughSharedFolderWithoutDuplicateShards() async throws {
    let files = FileManager.default
    let workspace = files.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("ActivitySyncTests-\(UUID().uuidString)", isDirectory: true)
    let shared = workspace.appendingPathComponent("shared", isDirectory: true)
    try files.createDirectory(at: shared, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: workspace) }
    let firstDevice = UUID()
    let secondDevice = UUID()
    let firstStore = ActivityStore(url: workspace.appendingPathComponent("first.sqlite"))
    let secondStore = ActivityStore(url: workspace.appendingPathComponent("second.sqlite"))
    let firstEngine = ActivitySyncEngine(key: key)
    let secondEngine = ActivitySyncEngine(key: key)
    let folder = ActivitySyncFolder(root: shared)
    var firstRows = [session(firstDevice, offset: 0), session(firstDevice, offset: 5)]
    firstRows[0].deviceName = "before-rename (MacBook Air)"
    let deviceName = "studio-laptop (MacBook Air)"
    firstRows[1].deviceName = deviceName
    let secondRows = [session(secondDevice, offset: 10), session(secondDevice, offset: 15)]
    let day = ActivitySyncShard.day(of: now)
    let interval = DateInterval(start: now, duration: 60)
    #expect(try await secondStore.sessions(in: interval).isEmpty)

    try await firstStore.insert([firstRows[1]])
    try await firstStore.insert([firstRows[0]])
    try await firstEngine.run(store: firstStore, device: firstDevice, repository: folder, now: now)
    let storedMarker = try await folder.read([ActivitySyncRemotePath.marker])
    let marker = try #require(storedMarker)
    let encryptedRoot = try await folder.list([])
    let cipher = ActivitySyncCipher(key: key)
    try cipher.authenticateMarker(marker)
    let month = try cipher.directoryName(String(day.prefix(7)), in: [])
    let path = try [month, cipher.directoryName(day, in: [month])]
    let originalNames = try await folder.list(path)
    #expect(originalNames.count == 1)
    try await secondEngine.run(
      store: secondStore, device: secondDevice, repository: folder, now: now)
    #expect(try await secondStore.sessions(in: interval) == firstRows)

    try await secondStore.insert(secondRows)
    try await secondEngine.run(
      store: secondStore, device: secondDevice, repository: folder, now: now)
    try await firstEngine.run(store: firstStore, device: firstDevice, repository: folder, now: now)
    #expect(try await firstStore.sessions(in: interval) == firstRows + secondRows)
    let names = try await folder.list(path)
    #expect(names.count == 2)
    #expect(originalNames.isSubset(of: names))

    try await ActivitySyncEngine(key: key).run(
      store: firstStore, device: firstDevice, repository: folder, now: now)
    try await ActivitySyncEngine(key: key).run(
      store: secondStore, device: secondDevice, repository: folder, now: now)
    #expect(try await firstStore.sessions(in: interval) == firstRows + secondRows)
    #expect(try await secondStore.sessions(in: interval) == firstRows + secondRows)
    #expect(try await secondStore.deviceNames() == [firstDevice: deviceName])
    #expect(try await firstStore.deviceNames() == [firstDevice: deviceName])
    #expect(try await folder.list(path) == names)
    for name in names {
      let shard = try cipher.shard(from: name, day: day, in: path)
      let object = path + [name]
      let stored = try await folder.read(object)
      let ciphertext = try #require(stored)
      let plaintext = try cipher.open(ciphertext, at: object)
      #expect(ciphertext != plaintext)
      #expect(ciphertext.range(of: Data("appName".utf8)) == nil)
      #expect(ciphertext.range(of: Data(deviceName.utf8)) == nil)
      #expect(!name.contains(shard.device.uuidString.lowercased()))
      #expect(!name.contains(shard.digest))
      #expect(!path.contains(day))
      #expect(!path.contains(shard.month))
      let rows = try shard.decode(plaintext)
      #expect(rows == (shard.device == firstDevice ? firstRows : secondRows))
    }

    let wrongKey = SymmetricKey(size: .bits256)
    let wrongDevice = UUID()
    let wrongStore = ActivityStore(url: nil)
    let localOnly = session(wrongDevice, offset: 20)
    try await wrongStore.insert([localOnly])
    await #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try await ActivitySyncEngine(key: wrongKey).run(
        store: wrongStore, device: wrongDevice, repository: folder, mode: .manual, now: now)
    }
    let unchanged = try await wrongStore.sessions(in: interval)
    let finalNames = try await folder.list(path)
    let finalRoot = try await folder.list([])
    #expect(unchanged == [localOnly])
    #expect(finalNames == names)
    #expect(finalRoot == encryptedRoot)
  }

  @Test func independentlyBootstrappedFoldersMergeDespiteDifferentSameKeyMarkers() async throws {
    let files = FileManager.default
    let workspace = files.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("ActivitySyncOffline-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: workspace) }
    let firstRoot = workspace.appendingPathComponent("first", isDirectory: true)
    let secondRoot = workspace.appendingPathComponent("second", isDirectory: true)
    let mergedRoot = workspace.appendingPathComponent("merged", isDirectory: true)
    for root in [firstRoot, secondRoot, mergedRoot] {
      try files.createDirectory(at: root, withIntermediateDirectories: true)
    }

    let firstDevice = UUID()
    let secondDevice = UUID()
    let firstStore = ActivityStore(url: workspace.appendingPathComponent("first.sqlite"))
    let secondStore = ActivityStore(url: workspace.appendingPathComponent("second.sqlite"))
    let firstRow = session(firstDevice, offset: 0)
    let secondRow = session(secondDevice, offset: 5)
    try await firstStore.insert([firstRow])
    try await secondStore.insert([secondRow])
    let firstEngine = ActivitySyncEngine(key: key)
    let secondEngine = ActivitySyncEngine(key: key)
    let firstFolder = ActivitySyncFolder(root: firstRoot)
    let secondFolder = ActivitySyncFolder(root: secondRoot)
    let mergedFolder = ActivitySyncFolder(root: mergedRoot)
    try await firstEngine.run(
      store: firstStore, device: firstDevice, repository: firstFolder, now: now)
    try await secondEngine.run(
      store: secondStore, device: secondDevice, repository: secondFolder, now: now)

    let markerPath = [ActivitySyncRemotePath.marker]
    let firstMarkerBytes = try await firstFolder.read(markerPath)
    let secondMarkerBytes = try await secondFolder.read(markerPath)
    let firstMarker = try #require(firstMarkerBytes)
    let secondMarker = try #require(secondMarkerBytes)
    #expect(firstMarker != secondMarker)
    let cipher = ActivitySyncCipher(key: key)
    try cipher.authenticateMarker(firstMarker)
    try cipher.authenticateMarker(secondMarker)
    let markerCreated = try await mergedFolder.create(secondMarker, at: markerPath)
    #expect(markerCreated)
    let markerConflict = try await mergedFolder.create(firstMarker, at: markerPath)
    #expect(!markerConflict)

    let day = ActivitySyncShard.day(of: now)
    let month = try cipher.directoryName(String(day.prefix(7)), in: [])
    let parent = try [month, cipher.directoryName(day, in: [month])]
    for source in [firstFolder, secondFolder] {
      let names = try await source.list(parent)
      let name = try #require(names.first)
      #expect(names.count == 1)
      let object = parent + [name]
      let stored = try await source.read(object)
      let ciphertext = try #require(stored)
      let copied = try await mergedFolder.create(ciphertext, at: object)
      #expect(copied)
    }

    // 模拟云盘保留第二个标记，但合并两台设备未修改过的密文分片。
    try await firstEngine.run(
      store: firstStore, device: firstDevice, repository: mergedFolder, now: now)
    try await secondEngine.run(
      store: secondStore, device: secondDevice, repository: mergedFolder, mode: .manual, now: now)
    let interval = DateInterval(start: now, duration: 60)
    let firstRows = try await firstStore.sessions(in: interval)
    let secondRows = try await secondStore.sessions(in: interval)
    let names = try await mergedFolder.list(parent)
    let marker = try await mergedFolder.read(markerPath)
    #expect(firstRows == [firstRow, secondRow])
    #expect(secondRows == firstRows)
    #expect(names.count == 2)
    #expect(marker == secondMarker)
  }

  @Test func concurrentCreationAcceptsDifferentCiphertextForSameShardAndRetryAddsNothing()
    async throws
  {
    let repository = Shards(key: key)
    let device = UUID()
    let store = ActivityStore(url: nil)
    try await store.insert([session(device, offset: 0)])
    await repository.simulateConcurrentCreation()
    try await ActivitySyncEngine(key: key).run(
      store: store, device: device, repository: repository, now: now)
    let once = await repository.files
    #expect(once.count == 2)
    #expect(await repository.reads == 1)

    try await ActivitySyncEngine(key: key).run(
      store: store, device: device, repository: repository, now: now)
    let twice = await repository.files
    #expect(once == twice)
    #expect(await repository.writes == 1)
  }

  @Test func rebuildingWithSameDeviceRestoresAllShardsBeforePublishing() async throws {
    let device = UUID()
    let repository = Shards(key: key)
    let original = (0..<7).map { session(device, offset: $0) }
    for row in original { _ = try await repository.seed([row]) }
    let store = ActivityStore(url: nil)
    let newRow = session(device, offset: 9)
    try await store.insert([newRow] + Array(original.suffix(3)))
    let engine = ActivitySyncEngine(key: key)
    try await engine.run(store: store, device: device, repository: repository, now: now)
    #expect(await repository.reads == 4)
    #expect(await repository.writes == 0)
    try await engine.run(store: store, device: device, repository: repository, now: now)
    #expect(await repository.writes == 1)
    let files = await repository.files.filter { $0.key.count == 3 }
    let cipher = try await repository.fixtureCipher()
    #expect(files.count == 8)
    for (path, data) in files {
      let shard = try cipher.shard(
        from: path[2], day: ActivitySyncShard.day(of: now), in: Array(path.prefix(2)))
      let rows = try shard.decode(cipher.open(data, at: path))
      #expect(rows.count == 1)
    }
    let data = try await store.exportDay(ActivitySyncShard.day(of: now), deviceID: device)
    #expect(Set(data.map(\.id)) == Set((original + [newRow]).map(\.id)))
    try await engine.run(store: store, device: device, repository: repository, now: now)
    #expect(await repository.reads == 7)
    #expect(await repository.writes == 1)
  }

  @Test func initiallyEmptyDeviceImportsAndPicksUpNewSameDayRecords() async throws {
    let source = UUID()
    let local = UUID()
    let engine = ActivitySyncEngine(key: key)
    let repository = Shards(key: key)
    let store = ActivityStore(url: nil)
    let first = session(source, offset: 0)
    let second = session(source, offset: 1)
    _ = try await repository.seed([first])
    try await confirmation("Imported records refresh the activity page") { notified in
      let observer = NotificationCenter.default.addObserver(
        forName: .init("XStatsActivitySyncFinished"), object: nil, queue: nil
      ) { note in
        if note.object as? ActivityStore === store { notified() }
      }
      defer { NotificationCenter.default.removeObserver(observer) }
      try await engine.run(store: store, device: local, repository: repository, now: now)
    }
    _ = try await repository.seed([second])
    try await engine.run(store: store, device: local, repository: repository, now: now)
    try await engine.run(store: store, device: local, repository: repository, now: now)
    #expect(await repository.reads == 2)
    #expect(await repository.writes == 0)
    let data = try await store.exportDay(ActivitySyncShard.day(of: now), deviceID: source)
    #expect(data == [first, second])
  }

  @Test func oneManualSyncImportsAllDiscoveredHistoricalDaysAndShards() async throws {
    let remote = UUID()
    let device = UUID()
    let repository = Shards(key: key)
    let offsets = [-105, -104, -74, -73, -44, -43]
    var rows = offsets.map { session(remote, offset: $0 * 86_400) }
    rows += (1...5).map { session(remote, offset: offsets[0] * 86_400 + $0) }
    for row in rows { _ = try await repository.seed([row]) }

    let interval = DateInterval(start: now.addingTimeInterval(-106 * 86_400), end: now)
    let automaticStore = ActivityStore(url: nil)
    try await ActivitySyncEngine(key: key).run(
      store: automaticStore, device: device, repository: repository, now: now)
    let partial = try await automaticStore.sessions(in: interval)
    #expect(partial.count == 4)

    let manualStore = ActivityStore(url: nil)
    try await ActivitySyncEngine(key: key).run(
      store: manualStore, device: device, repository: repository, mode: .manual, now: now)
    let imported = try await manualStore.sessions(in: interval)
    let reads = await repository.reads
    #expect(imported == rows.sorted { $0.start < $1.start })
    #expect(reads == partial.count + rows.count)
  }

  @Test func manualSyncAttemptsAFailedShardOnceAndStillImportsLaterMonths() async throws {
    let remote = UUID()
    let device = UUID()
    let repository = Shards(key: key)
    let invalid = session(remote, offset: -105 * 86_400)
    let valid = session(remote, offset: -43 * 86_400)
    _ = try await repository.seed([invalid, valid])
    _ = try await repository.seed([valid])
    let store = ActivityStore(url: nil)
    let engine = ActivitySyncEngine(key: key)

    await #expect(throws: ActivitySyncFailure.self) {
      try await engine.run(
        store: store, device: device, repository: repository, mode: .manual, now: now)
    }
    let interval = DateInterval(start: now.addingTimeInterval(-106 * 86_400), end: now)
    let imported = try await store.sessions(in: interval)
    let reads = await repository.reads
    #expect(imported == [valid])
    #expect(reads == 2)
  }

  @Test func rejectsCorruptContentAndMismatchedDeviceOrDay() throws {
    let device = UUID()
    let data = try ActivitySyncShard.encode([session(device, offset: 0)])
    let digest = ActivitySyncShard.checksum(data)
    let shard = ActivitySyncShard(
      day: ActivitySyncShard.day(of: now), device: device, digest: digest)
    #expect(throws: ActivitySyncFailure.self) { try shard.decode(data + Data([32])) }
    #expect(throws: ActivitySyncFailure.self) {
      try ActivitySyncShard(day: "2024-11-14", device: device, digest: digest).decode(data)
    }
    #expect(throws: ActivitySyncFailure.self) {
      try ActivitySyncShard(day: shard.day, device: UUID(), digest: digest).decode(data)
    }
    #expect(!ActivitySyncShard.validDay("2025-02-29"))
  }

  @Test func authenticatesRandomizedCiphertextAndBindsItToTheDatasetAndPath() throws {
    let first = ActivitySyncCipher(key: key)
    let second = ActivitySyncCipher(key: SymmetricKey(size: .bits256))
    let device = UUID()
    let day = ActivitySyncShard.day(of: now)
    let data = try ActivitySyncShard.encode([session(device, offset: 0)])
    let shard = ActivitySyncShard(
      day: day, device: device, digest: ActivitySyncShard.checksum(data))
    let firstPath = try first.path(for: shard)
    let samePath = try first.path(for: shard)
    let secondPath = try second.path(for: shard)
    let firstSeal = try first.seal(data, at: firstPath)
    let secondSeal = try first.seal(data, at: firstPath)
    #expect(firstPath == samePath)
    #expect(firstPath != secondPath)
    #expect(firstSeal.prefix(12) != secondSeal.prefix(12))
    #expect(firstSeal.count == data.count + ActivitySyncCipher.overhead)
    #expect(try first.open(firstSeal, at: firstPath) == data)
    #expect(try first.open(secondSeal, at: firstPath) == data)
    #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try second.open(firstSeal, at: firstPath)
    }
    #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try first.open(firstSeal, at: secondPath)
    }
    #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try first.open(data, at: firstPath)
    }
    var modified = firstSeal
    modified[modified.index(before: modified.endIndex)] ^= 1
    #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try first.open(modified, at: firstPath)
    }
    #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try second.directoryName(from: firstPath[0], in: [])
    }
  }

  @Test func populatedRootWithoutAuthenticatedMarkerIsNeverReinitialized() async throws {
    let repository = Shards(key: key)
    let row = session(UUID(), offset: 0)
    let data = try ActivitySyncShard.encode([row])
    let shard = ActivitySyncShard(
      day: ActivitySyncShard.day(of: now), device: row.deviceID,
      digest: ActivitySyncShard.checksum(data))
    let cipher = ActivitySyncCipher(key: key)
    let path = try cipher.path(for: shard)
    let created = try await repository.create(cipher.seal(data, at: path), at: path)
    #expect(created)

    let store = ActivityStore(url: nil)
    await #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try await ActivitySyncEngine(key: key).run(
        store: store, device: UUID(), repository: repository, now: now)
    }
    let files = await repository.files
    let imported = try await store.sessions(in: DateInterval(start: now, duration: 60))
    #expect(files.count == 1)
    #expect(imported.isEmpty)
  }

  @Test func wrongKeyTamperingAndAuthenticatedWrongIdentityNeverReplaceRemoteMarker() async throws {
    let cipher = ActivitySyncCipher(key: key)
    let otherCipher = ActivitySyncCipher(key: SymmetricKey(size: .bits256))
    var tampered = try cipher.makeMarker()
    tampered[tampered.startIndex] ^= 1
    let markerKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, salt: Data(), info: Data("XStats.Activity.v2/marker".utf8),
      outputByteCount: 32)
    let wrongIdentity = try AES.GCM.seal(
      Data(repeating: 0, count: 32), using: markerKey,
      authenticating: Data("XStats.Activity.v2/dataset".utf8))
    let wrongIdentityMarker = try #require(wrongIdentity.combined)
    let localDevice = UUID()
    let store = ActivityStore(url: nil)
    let row = session(localDevice, offset: 0)
    try await store.insert([row])
    let markerPath = [ActivitySyncRemotePath.marker]
    for invalidMarker in [try otherCipher.makeMarker(), tampered, wrongIdentityMarker] {
      let repository = Shards(key: key)
      let created = try await repository.create(invalidMarker, at: markerPath)
      #expect(created)
      await #expect(throws: ActivitySyncFailure.authenticationFailed) {
        try await ActivitySyncEngine(key: key).run(
          store: store, device: localDevice, repository: repository, now: now)
      }
      let contents = await repository.files
      #expect(contents == [markerPath: invalidMarker])
      #expect(await repository.writes == 0)
      #expect(await repository.markerCreateAttempts == 1)
    }
    let local = try await store.sessions(in: DateInterval(start: now, duration: 60))
    #expect(local == [row])
  }

  @Test func cloudPlaceholderIsDiscoveredAndRequestedBeforeImport() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString)
    let repository = Shards(key: key)
    let device = UUID()
    let object = try await repository.seed([session(device, offset: 0)])
    let path = Array(object.dropLast())
    let name = try #require(object.last)
    let directory = ([ActivitySyncRemotePath.namespace] + path).reduce(root) {
      $0.appendingPathComponent($1, isDirectory: true)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canonical = directory.appendingPathComponent(name)
    let placeholder = directory.appendingPathComponent(".\(name).icloud")
    try Data().write(to: placeholder)
    try await confirmation("Requested cloud content") { requested in
      let folder = ActivitySyncFolder(root: root, isICloud: true) { url in
        #expect(url.path == canonical.path)
        requested()
      }
      let listed = try await folder.list(path)
      #expect(listed == [name])
      await #expect(throws: ActivitySyncFailure.cloudPending) { try await folder.read(object) }
    }
    try FileManager.default.removeItem(at: placeholder)
    let folder = ActivitySyncFolder(root: root)
    let stored = await repository.read(object)
    let bytes = try #require(stored)
    let created = try await folder.create(bytes, at: object)
    #expect(created)
    let collided = try await folder.create(Data(), at: object)
    #expect(!collided)
    let result = try await folder.read(object)
    #expect(result == bytes)
  }

  @MainActor @Test func localModeUsesOnlyTheInjectedPreferencesAndCanPause() throws {
    let suite = "ActivitySyncTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ActivityStore(url: nil)
    #expect(
      ActivitySyncController(store: store, deviceID: UUID(), defaults: defaults).provider == .iCloud
    )
    defaults.set("local", forKey: "activity.sync.provider")
    let controller = ActivitySyncController(store: store, deviceID: UUID(), defaults: defaults)
    controller.setActive(true)
    controller.dataChanged()
    controller.syncNow()
    #expect(controller.active && !controller.syncing && controller.message == nil)
    controller.setActive(false)
    #expect(!controller.active)
  }
}
