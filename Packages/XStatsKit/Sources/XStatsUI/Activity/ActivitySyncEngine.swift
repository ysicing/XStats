// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

enum ActivitySyncFailure: Error, Equatable {
  case cloudUnavailable, downloadRequested, folderUnavailable, invalidShard, limit, invalidListing,
    authenticationFailed,
    busy, keyPending
}

struct ActivitySyncShard: Hashable, Sendable {
  static let batchSize = 64
  let day: String
  let device: UUID
  let digest: String
  var month: String { String(day.prefix(7)) }

  static func validDay(_ day: String) -> Bool {
    guard day.utf8.count == 10, validMonth(String(day.prefix(7))), day.dropFirst(7).first == "-",
      day.suffix(2).utf8.allSatisfy({ (48...57).contains($0) }),
      let date = try? utc.parse(day)
    else { return false }
    return self.day(of: date) == day
  }

  static func validMonth(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 7 && bytes[4] == 45 && value.prefix(4) != "0000"
      && (bytes.prefix(4) + bytes.suffix(2)).allSatisfy { (48...57).contains($0) }
      && ("01"..."12").contains(String(value.suffix(2)))
  }

  static let utc = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
  static func day(of date: Date) -> String {
    Date(timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate)).formatted(utc)
  }

  static func checksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func encode(_ sessions: [ActivitySession]) throws -> Data {
    guard sessions.count <= Self.batchSize else { throw ActivitySyncFailure.limit }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(sessions)
    guard data.count <= ActivitySyncRemotePath.maximumBytes - ActivitySyncCipher.overhead else {
      throw ActivitySyncFailure.limit
    }
    return data
  }

  func decode(_ data: Data) throws -> [ActivitySession] {
    guard data.count <= ActivitySyncRemotePath.maximumBytes - ActivitySyncCipher.overhead else {
      throw ActivitySyncFailure.limit
    }
    guard Self.checksum(data) == digest else { throw ActivitySyncFailure.invalidShard }
    let sessions = try JSONDecoder().decode([ActivitySession].self, from: data)
    guard !sessions.isEmpty, sessions.count <= Self.batchSize else {
      throw ActivitySyncFailure.limit
    }
    var ids = Set<UUID>()
    for session in sessions {
      try Task.checkCancellation()
      guard session.deviceID == device, session.start.timeIntervalSince1970 >= -62_135_596_800,
        session.end.timeIntervalSince1970 <= 253_402_300_800, session.start < session.end,
        Self.day(of: session.start) == day, ids.insert(session.id).inserted
      else { throw ActivitySyncFailure.invalidShard }
    }
    return sessions
  }
}

protocol ActivitySyncRepository: Sendable {
  func list(_ directory: [String]) async throws -> Set<String>
  func listActivityObjects(_ directory: [String]) async throws -> ActivitySyncListing
  func read(_ path: [String]) async throws -> Data?
  func create(_ data: Data, at path: [String]) async throws -> Bool
  func replaceMetadata(_ data: Data, at path: [String]) async throws
}

struct ActivitySyncListing: Sendable {
  var names: Set<String> = []
  var versions: [String: String] = [:]
}

extension ActivitySyncRepository {
  func listActivityObjects(_ directory: [String]) async throws -> ActivitySyncListing {
    try await ActivitySyncListing(names: list(directory))
  }

  func replaceMetadata(_ data: Data, at path: [String]) async throws {
    throw ActivitySyncFailure.folderUnavailable
  }
}

enum ActivitySyncMode: Equatable, Sendable {
  case automatic, manual
}

/// 每个设置目标独享游标和成功记录；失败分片保留重试机会，不能阻塞其他设备。
actor ActivitySyncEngine {
  private var cipher: ActivitySyncCipher
  private var key: SymmetricKey
  var authenticatedKey: SymmetricKey? { authenticatedDataset ? key : nil }
  private(set) var datasetIdentifier: String? = nil
  private let sharedKeys: ActivitySharedKeys?
  private var publishedMarker: Data?
  private let localSyncKey: SymmetricKey
  private var authenticatedDataset = false
  private var running = false
  private var lastMonth = ""
  private var cursors: [String: String] = [:]
  private var importedRecords = false
  private(set) var continuationDay: String?

  init(key: SymmetricKey, sharedKeys: ActivitySharedKeys? = nil) {
    self.key = key
    self.localSyncKey = key
    self.sharedKeys = sharedKeys
    cipher = ActivitySyncCipher(key: key)
  }

  func run(
    store: ActivityStore, device: UUID, repository: any ActivitySyncRepository,
    mode: ActivitySyncMode = .automatic, now: Date = Date()
  ) async throws {
    try Task.checkCancellation()
    guard !running else { throw ActivitySyncFailure.busy }
    running = true
    importedRecords = false
    defer {
      if importedRecords {
        NotificationCenter.default.post(name: .init("XStatsActivitySyncFinished"), object: store)
      }
      running = false
    }
    let today = ActivitySyncShard.day(of: now)
    let current = String(today.prefix(7))
    try await authenticateDataset(repository: repository)
    try Task.checkCancellation()
    let root = try await repository.list([])
    let remote = try listedDirectories(
      root.subtracting([ActivitySyncRemotePath.marker, ActivitySyncRemotePath.metadata]), in: [])
    let days = try await store.localDays(deviceID: device)
    let months = Set(remote.keys)
      .union(days.map { String($0.prefix(7)) })
    var selected = [current]
    let historical = months.filter { $0 != current }.sorted()
    if mode == .manual {
      selected += historical
    } else if let next = historical.first(where: { $0 > lastMonth }) ?? historical.first {
      selected.append(next)
      lastMonth = next
    }
    var failure: (any Error)?
    let resume = mode == .automatic ? continuationDay : nil
    continuationDay = nil
    var visited = Set<String>()
    if let resume {
      do {
        if try await synchronize(
          resume, listed: true, store: store, device: device, repository: repository, mode: mode)
        {
          continuationDay = resume
        }
        visited.insert(resume)
      } catch {
        try Task.checkCancellation()
        failure = error
        visited.insert(resume)
      }
    }
    for month in selected {
      try Task.checkCancellation()
      do {
        let remoteDays: [String: String]
        if let remoteMonth = remote[month] {
          remoteDays = try listedDirectories(
            try await repository.list([remoteMonth]), in: [remoteMonth])
          guard remoteDays.keys.allSatisfy({ $0.hasPrefix(month) }) else {
            throw ActivitySyncFailure.invalidListing
          }
        } else {
          remoteDays = [:]
        }
        let available = Set(remoteDays.keys).union(days.filter { $0.hasPrefix(month) })
        let otherDays = Array(available.filter { $0 != today })
        var batch = mode == .manual ? otherDays.sorted() : slice(otherDays, key: month, limit: 1)
        if available.contains(today) { batch.insert(today, at: 0) }
        for day in batch where !visited.contains(day) {
          try Task.checkCancellation()
          do {
            if try await synchronize(
              day, listed: remoteDays[day] != nil, store: store, device: device,
              repository: repository, mode: mode), continuationDay == nil
            {
              continuationDay = day
            }
          } catch {
            try Task.checkCancellation()
            failure = error
          }
        }
      } catch {
        try Task.checkCancellation()
        failure = error
      }
    }
    if let failure { throw failure }
  }

  @discardableResult
  func exchangeMetadata(
    device: UUID, repository: any ActivitySyncRepository,
    transform: @Sendable ([UUID: Data]) async throws -> Data?
  ) async throws -> [UUID: Data]? {
    try Task.checkCancellation()
    guard !running else { throw ActivitySyncFailure.busy }
    running = true
    defer { running = false }

    try await authenticateDataset(repository: repository)
    let verifiedMarker = publishedMarker
    try Task.checkCancellation()
    let snapshot = try await readMetadata(repository: repository)
    let updated = try await transform(snapshot)
    try Task.checkCancellation()
    guard let updated else { return nil }
    guard snapshot[device] != nil || snapshot.count < ActivitySyncRemotePath.maximumMetadataEntries
    else { throw ActivitySyncFailure.limit }
    let path = try cipher.metadataPath(for: device)
    let ciphertext = try cipher.sealMetadata(updated, at: path)
    try await authenticateDataset(repository: repository)
    guard publishedMarker == verifiedMarker else {
      throw ActivitySyncFailure.authenticationFailed
    }
    try Task.checkCancellation()
    try await repository.replaceMetadata(ciphertext, at: path)

    try Task.checkCancellation()
    try await authenticateDataset(repository: repository)
    guard publishedMarker == verifiedMarker else {
      throw ActivitySyncFailure.authenticationFailed
    }
    let verified = try await readMetadata(repository: repository)
    guard verified[device] == updated else { throw ActivitySyncFailure.authenticationFailed }
    return verified
  }

  private func readMetadata(repository: any ActivitySyncRepository) async throws -> [UUID: Data] {
    let directory = [ActivitySyncRemotePath.metadata]
    let entries = try await repository.list(directory)
    guard entries.count <= ActivitySyncRemotePath.maximumMetadataEntries else {
      throw ActivitySyncFailure.limit
    }
    var snapshot: [UUID: Data] = [:]
    for name in entries {
      try Task.checkCancellation()
      let path = directory + [name]
      guard ActivitySyncRemotePath.validMetadataObject(path),
        let ciphertext = try await repository.read(path)
      else { throw ActivitySyncFailure.invalidListing }
      let metadata = try cipher.openMetadata(ciphertext, at: path)
      guard snapshot.updateValue(metadata.data, forKey: metadata.device) == nil else {
        throw ActivitySyncFailure.invalidListing
      }
    }
    try Task.checkCancellation()
    return snapshot
  }

  private func authenticateDataset(repository: any ActivitySyncRepository) async throws {
    let path = [ActivitySyncRemotePath.marker]
    if let bytes = try await repository.read(path) {
      try acceptMarker(bytes)
      return
    }

    // 标记丢失或远端已有对象时不能重新初始化。并发创建后只信任已存储且验证通过的标记。
    guard !authenticatedDataset else { throw ActivitySyncFailure.authenticationFailed }
    let root = try await repository.list([])
    if root.isEmpty {
      try Task.checkCancellation()
      if let sharedKeys {
        let preferred = try sharedKeys.read("default") ?? sharedKeys.insert("default", key)
        key = preferred
        cipher = ActivitySyncCipher(key: preferred)
      }
      let marker = try cipher.makeMarker()
      if try await repository.create(marker, at: path) {
        try acceptMarker(marker)
        return
      }
    } else if !root.contains(ActivitySyncRemotePath.marker) {
      throw ActivitySyncFailure.authenticationFailed
    }
    guard let winner = try await repository.read(path) else {
      throw ActivitySyncFailure.authenticationFailed
    }
    try acceptMarker(winner)
  }

  private func acceptMarker(_ bytes: Data) throws {
    guard bytes.count == 60 else { throw ActivitySyncFailure.authenticationFailed }
    if publishedMarker == bytes { return }
    var identifier = try? cipher.authenticateMarker(bytes)
    if let sharedKeys {
      let account = ActivitySyncShard.checksum(bytes)
      if identifier == nil {
        // 已经使用过的目标不能被另一份数据集静默替换；只有首次加入才从钥匙串选择匹配的密钥。
        guard !authenticatedDataset else { throw ActivitySyncFailure.authenticationFailed }
        let candidates = [
          localSyncKey, try sharedKeys.read(account), try sharedKeys.read("default"),
        ]
        for candidate in candidates.compactMap({ $0 }) {
          let candidateCipher = ActivitySyncCipher(key: candidate)
          guard let match = try? candidateCipher.authenticateMarker(bytes) else { continue }
          key = candidate
          cipher = candidateCipher
          identifier = match
          break
        }
        guard identifier != nil else { throw ActivitySyncFailure.keyPending }
      }
      guard try sharedKeys.insert(account, key) == key else {
        throw ActivitySyncFailure.authenticationFailed
      }
    }
    guard let identifier else { throw ActivitySyncFailure.authenticationFailed }
    publishedMarker = bytes
    datasetIdentifier = identifier
    authenticatedDataset = true
  }

  private func listedDirectories(_ entries: Set<String>, in path: [String]) throws -> [String:
    String]
  {
    var result: [String: String] = [:]
    for entry in entries {
      try Task.checkCancellation()
      let logical = try cipher.directoryName(from: entry, in: path)
      result[logical] = entry
    }
    return result
  }

  private func synchronize(
    _ day: String, listed: Bool, store: ActivityStore, device: UUID,
    repository: any ActivitySyncRepository, mode: ActivitySyncMode
  ) async throws -> Bool {
    guard let datasetIdentifier else { throw ActivitySyncFailure.authenticationFailed }
    let dataset = datasetIdentifier + "/" + device.uuidString
    let remoteMonth = try cipher.directoryName(String(day.prefix(7)), in: [])
    let parent = try [remoteMonth, cipher.directoryName(day, in: [remoteMonth])]
    let listing = listed ? try await repository.listActivityObjects(parent) : ActivitySyncListing()
    let entries = listing.names
    var shards: [[String]: ActivitySyncShard] = [:]
    var versions: [[String]: String] = [:]
    var ownPage: (number: UInt16, count: Int)?
    var failure: (any Error)?
    var ownListingFailed = false
    var ownPartitions: [String] = []
    var peerPartitions: [String] = []
    for name in entries.sorted() {
      try Task.checkCancellation()
      do {
        if ActivitySyncRemotePath.isPartition(name) {
          let partition = try cipher.partitionInfo(name, in: parent)
          if partition.device == device {
            ownPartitions.append(name)
          } else {
            peerPartitions.append(name)
          }
        } else {
          let path = parent + [name]
          shards[path] = try cipher.shard(from: name, day: day, in: parent)
          versions[path] = listing.versions[name]
        }
      } catch {
        failure = error
        ownListingFailed = true
      }
    }
    let scannedPeers =
      mode == .manual ? peerPartitions : slice(peerPartitions, key: "pages/" + day, limit: 4)
    for name in ownPartitions + scannedPeers {
      try Task.checkCancellation()
      let partition = try cipher.partitionInfo(name, in: parent)
      let directory = parent + [name]
      do {
        let children = try await repository.listActivityObjects(directory)
        if partition.device == device, ownPage.map({ $0.number < partition.page }) ?? true {
          ownPage = (partition.page, children.names.count)
        }
        for child in children.names {
          try Task.checkCancellation()
          let shard = try cipher.shard(from: child, day: day, in: directory)
          guard shard.device == partition.device else { throw ActivitySyncFailure.invalidShard }
          let path = directory + [child]
          shards[path] = shard
          versions[path] = children.versions[child]
        }
      } catch {
        try Task.checkCancellation()
        failure = error
        if partition.device == device { ownListingFailed = true }
      }
    }
    var dayEntries = entries.count
    let receipts = try await store.syncReceipts(dataset: dataset, paths: Array(shards.keys))
    var published = Set<UUID>()
    var pending = [String: [String]]()
    for (path, shard) in shards {
      if let receipt = receipts[path],
        versions[path].map({ $0 == receipt.version }) ?? (mode != .manual || shard.device != device)
      {
        published.formUnion(receipt.ownRecords)
      } else {
        pending[path.dropFirst(2).joined(separator: "/")] = path
      }
    }
    let names = Array(pending.keys)
    let selected = mode == .manual ? names.sorted() : slice(names, key: day, limit: 4)
    var unverifiedOwn = pending.values.count { shards[$0]?.device == device }
    for name in selected {
      guard let path = pending[name], let shard = shards[path] else { continue }
      do {
        guard let ciphertext = try await repository.read(path) else {
          throw ActivitySyncFailure.invalidListing
        }
        let sessions = try shard.decode(cipher.open(ciphertext, at: path))
        let ids = shard.device == device ? sessions.map(\.id) : []
        let changed = try await store.insert(
          sessions,
          receipt: .init(dataset: dataset, path: path, ownRecords: ids, version: versions[path]))
        importedRecords = importedRecords || changed
        if shard.device == device {
          published.formUnion(ids)
          unverifiedOwn -= 1
        }
      } catch {
        try Task.checkCancellation()
        failure = error
      }
    }
    var outstanding = selected.count < names.count
    if unverifiedOwn == 0 && !ownListingFailed {
      // 手动同步遍历本轮快照；自动同步限制每轮批数，单个分片的上限相同。
      let batchSize = ActivitySyncShard.batchSize
      let missing = try await store.unpublishedSessions(
        on: day, deviceID: device, excluding: published,
        limit: mode == .manual ? nil : 2 * batchSize + 1)
      let count = mode == .manual ? missing.count : min(missing.count, 2 * batchSize)
      outstanding = outstanding || count < missing.count
      for offset in stride(from: 0, to: count, by: batchSize) {
        try Task.checkCancellation()
        let batch = Array(missing[offset..<min(offset + batchSize, missing.count)])
        let plaintext = try ActivitySyncShard.encode(batch)
        let shard = ActivitySyncShard(
          day: day, device: device, digest: ActivitySyncShard.checksum(plaintext))
        var writeDirectory = parent
        if ownPage != nil || dayEntries >= ActivitySyncRemotePath.flatDayThreshold {
          var partition = ownPage ?? (number: 0, count: 0)
          if partition.count >= ActivitySyncRemotePath.flatDayThreshold {
            guard partition.number < UInt16.max else { throw ActivitySyncFailure.limit }
            partition = (partition.number + 1, 0)
          }
          if partition.count == 0 {
            guard dayEntries < ActivitySyncRemotePath.maximumEntries else {
              throw ActivitySyncFailure.limit
            }
            dayEntries += 1
          }
          writeDirectory += [try cipher.partition(for: device, page: partition.number, in: parent)]
          partition.count += 1
          ownPage = partition
        } else {
          dayEntries += 1
        }
        let name = try cipher.shardName(shard, in: writeDirectory)
        let path = writeDirectory + [name]
        let ciphertext = try cipher.seal(plaintext, at: path)
        let created = try await repository.create(ciphertext, at: path)
        if !created {
          guard let existing = try await repository.read(path),
            try cipher.open(existing, at: path) == plaintext
          else { throw ActivitySyncFailure.invalidShard }
        }
        try await store.insert(
          [], receipt: .init(dataset: dataset, path: path, ownRecords: batch.map(\.id)))
      }
    }
    if let failure { throw failure }
    return outstanding
  }

  private func slice(_ names: [String], key: String, limit: Int) -> [String] {
    let sorted = names.sorted()
    let pivot = sorted.firstIndex { $0 > (cursors[key] ?? "") } ?? sorted.endIndex
    let result = Array((sorted[pivot...] + sorted[..<pivot]).prefix(limit))
    if cursors.count >= 8192 { cursors.removeAll(keepingCapacity: true) }
    if let last = result.last { cursors[key] = last }
    return result
  }
}
