// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

struct ActivitySyncCipher: Sendable {
  static let overhead = 28
  private static let datasetLength = 32
  private static let markerContext = Data("XStats.Activity.v2/dataset".utf8)
  private let datasetIdentity: Data
  private let markerKey: SymmetricKey
  private let encryptionKey: SymmetricKey
  private let metadataKey: SymmetricKey
  private let nameKey: SymmetricKey

  init(key: SymmetricKey) {
    // 两台设备可在离线目录独立初始化。同一恢复密钥必须始终产生同一数据集身份。
    let identity = Self.derive(key, salt: Data(), info: "XStats.Activity.v2/dataset-identity")
      .withUnsafeBytes { Data($0) }
    datasetIdentity = identity
    markerKey = Self.derive(key, salt: Data(), info: "XStats.Activity.v2/marker")
    encryptionKey = Self.derive(key, salt: identity, info: "XStats.Activity.v2/payload")
    metadataKey = Self.derive(key, salt: identity, info: "XStats.Activity.v2/metadata")
    nameKey = Self.derive(key, salt: identity, info: "XStats.Activity.v2/name")
  }

  func makeMarker() throws -> Data {
    try Self.seal(datasetIdentity, key: markerKey, context: Self.markerContext)
  }

  @discardableResult
  func authenticateMarker(_ bytes: Data) throws -> String {
    guard bytes.count == Self.datasetLength + Self.overhead,
      try Self.open(bytes, key: markerKey, context: Self.markerContext) == datasetIdentity
    else { throw ActivitySyncFailure.authenticationFailed }
    return ActivitySyncShard.checksum(datasetIdentity)
  }

  func directoryName(_ logical: String, in parent: [String]) throws -> String {
    let isMonth = parent.isEmpty
    let validDate =
      isMonth ? ActivitySyncShard.validMonth(logical) : ActivitySyncShard.validDay(logical)
    guard validDate, parent.count < 2, ActivitySyncRemotePath.validShardDirectory(parent)
    else { throw ActivitySyncFailure.invalidListing }
    return try wrap(Data(logical.utf8), tag: isMonth ? 1 : 2, length: 16, parent: parent)
  }

  func directoryName(from remote: String, in parent: [String]) throws -> String {
    guard parent.count < 2, ActivitySyncRemotePath.validShardDirectory(parent)
    else { throw ActivitySyncFailure.invalidListing }
    let isMonth = parent.isEmpty
    let bytes = try unwrap(remote, tag: isMonth ? 1 : 2, length: isMonth ? 7 : 10, parent: parent)
    let logical = String(decoding: bytes, as: UTF8.self)
    guard isMonth ? ActivitySyncShard.validMonth(logical) : ActivitySyncShard.validDay(logical)
    else { throw ActivitySyncFailure.invalidListing }
    return logical
  }

  func shardName(_ shard: ActivitySyncShard, in parent: [String]) throws -> String {
    guard (2...3).contains(parent.count), ActivitySyncRemotePath.validShardDirectory(parent),
      shard.digest.utf8.prefix(65).count == 64, let digest = Self.unhex(shard.digest)
    else { throw ActivitySyncFailure.invalidShard }
    var uuid = shard.device.uuid
    var bytes = withUnsafeBytes(of: &uuid) { Data($0) }
    bytes.append(digest)
    return try wrap(bytes, tag: 3, length: 56, parent: parent)
  }

  func shard(from remote: String, day: String, in parent: [String]) throws -> ActivitySyncShard {
    guard (2...3).contains(parent.count), ActivitySyncRemotePath.validShardDirectory(parent)
    else { throw ActivitySyncFailure.invalidListing }
    let bytes = try unwrap(remote, tag: 3, length: 48, parent: parent)
    return ActivitySyncShard(
      day: day, device: Self.device(from: bytes), digest: Self.hex(bytes.dropFirst(16)))
  }

  func partition(for device: UUID, page: UInt16, in parent: [String]) throws -> String {
    guard parent.count == 2, ActivitySyncRemotePath.validShardDirectory(parent)
    else { throw ActivitySyncFailure.invalidListing }
    var bytes = withUnsafeBytes(of: device.uuid) { Data($0) }
    bytes.append(UInt8(page >> 8))
    bytes.append(UInt8(truncatingIfNeeded: page))
    return try wrap(bytes, tag: 5, length: 24, parent: parent)
  }

  func partitionInfo(_ name: String, in parent: [String]) throws -> (device: UUID, page: UInt16) {
    guard parent.count == 2, ActivitySyncRemotePath.isPartition(name)
    else { throw ActivitySyncFailure.invalidListing }
    let bytes = try unwrap(name, tag: 5, length: 18, parent: parent)
    return (Self.device(from: bytes), UInt16(bytes[16]) << 8 | UInt16(bytes[17]))
  }

  func path(for shard: ActivitySyncShard) throws -> [String] {
    let month = try directoryName(shard.month, in: [])
    let day = try directoryName(shard.day, in: [month])
    return try [month, day, shardName(shard, in: [month, day])]
  }

  func seal(_ plaintext: Data, at path: [String]) throws -> Data {
    guard ActivitySyncRemotePath.validActivityObject(path)
    else { throw ActivitySyncFailure.invalidListing }
    guard plaintext.count <= ActivitySyncRemotePath.maximumBytes - Self.overhead else {
      throw ActivitySyncFailure.limit
    }
    return try Self.seal(plaintext, key: encryptionKey, context: context(for: path))
  }

  func open(_ ciphertext: Data, at path: [String]) throws -> Data {
    guard ActivitySyncRemotePath.validActivityObject(path)
    else { throw ActivitySyncFailure.invalidListing }
    guard ciphertext.count <= ActivitySyncRemotePath.maximumBytes else {
      throw ActivitySyncFailure.limit
    }
    return try Self.open(ciphertext, key: encryptionKey, context: context(for: path))
  }

  func metadataPath(for device: UUID) throws -> [String] {
    let directory = [ActivitySyncRemotePath.metadata]
    let bytes = withUnsafeBytes(of: device.uuid) { Data($0) }
    let name = try wrap(bytes, tag: 4, length: 24, parent: directory)
    return directory + [name]
  }

  func sealMetadata(_ plaintext: Data, at path: [String]) throws -> Data {
    guard ActivitySyncRemotePath.validMetadataObject(path) else {
      throw ActivitySyncFailure.invalidListing
    }
    guard plaintext.count <= ActivitySyncRemotePath.maximumMetadataBytes - Self.overhead else {
      throw ActivitySyncFailure.limit
    }
    return try Self.seal(plaintext, key: metadataKey, context: metadataContext(for: path))
  }

  func openMetadata(_ ciphertext: Data, at path: [String]) throws -> (device: UUID, data: Data) {
    guard ActivitySyncRemotePath.validMetadataObject(path) else {
      throw ActivitySyncFailure.invalidListing
    }
    guard ciphertext.count <= ActivitySyncRemotePath.maximumMetadataBytes else {
      throw ActivitySyncFailure.limit
    }
    let owner = try unwrap(path[1], tag: 4, length: 16, parent: [ActivitySyncRemotePath.metadata])
    let plaintext = try Self.open(ciphertext, key: metadataKey, context: metadataContext(for: path))
    return (Self.device(from: owner), plaintext)
  }

  private func metadataContext(for path: [String]) -> Data {
    Data(("XStats.Activity.v2/" + path.joined(separator: "/")).utf8)
  }

  private static func device(from bytes: Data) -> UUID {
    UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  // RFC 3394 的封装结果可逆且确定。域标签、定长填充和父目录派生密钥绑定对象位置。
  private func wrap(_ bytes: Data, tag: UInt8, length: Int, parent: [String]) throws -> String {
    var padded = Data([tag])
    padded.append(bytes)
    padded.append(Data(count: length - padded.count))
    let wrapped = try AES.KeyWrap.wrap(SymmetricKey(data: padded), using: wrappingKey(for: parent))
    return Self.hex(wrapped)
  }

  private func unwrap(_ name: String, tag: UInt8, length: Int, parent: [String]) throws -> Data {
    guard ActivitySyncRemotePath.validChild(name, in: parent),
      name != ActivitySyncRemotePath.marker,
      let wrapped = Self.unhex(name)
    else { throw ActivitySyncFailure.invalidListing }
    let padded: Data
    do {
      let unwrapped = try AES.KeyWrap.unwrap(wrapped, using: wrappingKey(for: parent))
      padded = unwrapped.withUnsafeBytes { Data($0) }
    } catch {
      throw ActivitySyncFailure.authenticationFailed
    }
    guard padded.count > length, padded.first == tag,
      padded.dropFirst(length + 1).allSatisfy({ $0 == 0 })
    else { throw ActivitySyncFailure.authenticationFailed }
    return Data(padded.dropFirst().prefix(length))
  }

  private func context(for path: [String]) -> Data {
    Data(("XStats.Activity.v2/shard/" + path.joined(separator: "/")).utf8)
  }

  private func wrappingKey(for parent: [String]) -> SymmetricKey {
    Self.derive(
      nameKey, salt: Data(), info: "XStats.Activity.v2/directory/" + parent.joined(separator: "/"))
  }

  private static func derive(_ key: SymmetricKey, salt: Data, info: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, salt: salt, info: Data(info.utf8), outputByteCount: 32)
  }

  private static func seal(_ data: Data, key: SymmetricKey, context: Data) throws -> Data {
    // CryptoKit 在省略 nonce 时生成随机的 96 位 nonce，并将它与密文和认证标签一起编码。
    guard let combined = try AES.GCM.seal(data, using: key, authenticating: context).combined
    else { throw ActivitySyncFailure.authenticationFailed }
    return combined
  }

  private static func open(_ data: Data, key: SymmetricKey, context: Data) throws -> Data {
    do {
      return try AES.GCM.open(
        AES.GCM.SealedBox(combined: data), using: key, authenticating: context)
    } catch {
      throw ActivitySyncFailure.authenticationFailed
    }
  }

  private static func hex(_ bytes: Data) -> String {
    let alphabet = Array("0123456789abcdef".utf8)
    return String(
      decoding: bytes.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }, as: UTF8.self)
  }

  private static func unhex(_ text: String) -> Data? {
    var result = Data()
    var high: UInt8?
    for byte in text.utf8 {
      let value: UInt8
      switch byte {
      case 48...57: value = byte - 48
      case 97...102: value = byte - 87
      default: return nil
      }
      if let upper = high {
        result.append((upper << 4) | value)
        high = nil
      } else {
        high = value
      }
    }
    return high == nil ? result : nil
  }
}
