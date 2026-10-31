// SPDX-License-Identifier: AGPL-3.0-or-later

import Compression
import CryptoKit
import Foundation

struct IPRegionManifest: Decodable, Sendable {
  static let baseURL = GeographyManifest.baseURL
    .appendingPathComponent("ip2region/\(IPRegionDatabase.version)", isDirectory: true)
  let schemaVersion: Int
  let version: String
  let files: [GeographyAsset]

  static func decode(_ data: Data) throws -> Self {
    guard data.count <= 64 * 1024 else { throw CocoaError(.coderReadCorrupt) }
    let manifest = try JSONDecoder().decode(Self.self, from: data)
    guard manifest.schemaVersion == 1, manifest.version == IPRegionDatabase.version,
      manifest.files.count == IPRegionDatabase.assets.count,
      Set(manifest.files.map(\.name)) == Set(IPRegionDatabase.assets.map(\.name))
    else { throw CocoaError(.coderReadCorrupt) }
    for file in manifest.files {
      guard let expected = IPRegionDatabase.assets.first(where: { $0.name == file.name }),
        file.bytes == expected.bytes, file.sha256 == expected.digest,
        file.compressedBytes > 0, file.compressedBytes <= 64 * 1024 * 1024,
        GeographyAsset.isDigest(file.compressedSHA256),
        file.file == file.name.replacingOccurrences(of: ".xdb", with: "-")
          + file.compressedSHA256 + ".lzfse"
      else { throw CocoaError(.coderReadCorrupt) }
    }
    return manifest
  }

  /// 压缩包和展开内容均分块校验；解压输出不能超过清单声明的固定原库大小。
  static func unpack(_ asset: GeographyAsset, from source: URL, to destination: URL) throws {
    guard asset.bytes > 0, asset.bytes <= 64 * 1024 * 1024,
      asset.compressedBytes > 0, asset.compressedBytes <= 64 * 1024 * 1024,
      try source.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.compressedBytes
    else { throw CocoaError(.coderReadCorrupt) }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    var compressedHash = SHA256()
    while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      compressedHash.update(data: data)
    }
    guard
      compressedHash.finalize().map({ String(format: "%02x", $0) }).joined()
        == asset.compressedSHA256
    else { throw CocoaError(.coderReadCorrupt) }
    try input.seek(toOffset: 0)
    let filter = try InputFilter(.decompress, using: .lzfse, bufferCapacity: 64 * 1024) { count in
      try Task.checkCancellation()
      return try input.read(upToCount: min(count, 64 * 1024))
    }
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var written = 0
    var hash = SHA256()
    while let data = try filter.readData(ofLength: 64 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      guard data.count <= asset.bytes - written else { throw CocoaError(.coderReadCorrupt) }
      try output.write(contentsOf: data)
      hash.update(data: data)
      written += data.count
    }
    guard written == asset.bytes,
      hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256
    else { throw CocoaError(.coderReadCorrupt) }
  }
}
