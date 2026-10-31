// SPDX-License-Identifier: AGPL-3.0-or-later

import Compression
import Foundation
import Testing
@testable import XStatsUI

struct IPRegionCDNTests {
  @Test func manifestPinsSourceVersionAndBothRawDatabases() throws {
    let valid = try manifestData()
    let manifest = try IPRegionManifest.decode(valid)
    #expect(manifest.files.count == 2)
    #expect(IPRegionManifest.baseURL.host == GeographyManifest.baseURL.host)
    #expect(IPRegionManifest.baseURL.path.hasSuffix("/ip2region/\(IPRegionDatabase.version)"))
    for mutation in 0..<7 {
      var json = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
      var files = try #require(json["files"] as? [[String: Any]])
      switch mutation {
      case 0: json["version"] = String(repeating: "a", count: 40)
      case 1: files[0]["file"] = "../database.lzfse"
      case 2: files[0]["sha256"] = String(repeating: "a", count: 64)
      case 3: files[0]["bytes"] = 1
      case 4: files[1] = files[0]
      case 5: files[0]["compressedBytes"] = 64 * 1024 * 1024 + 1
      default: json["schemaVersion"] = 2
      }
      json["files"] = files
      #expect(throws: (any Error).self) {
        try IPRegionManifest.decode(JSONSerialization.data(withJSONObject: json))
      }
    }
  }

  @Test func fileDecompressionChecksBothHashesAndBoundsExpandedOutput() throws {
    let raw = Data((0..<(256 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0) })
    let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("source.lzfse")
    let output = root.appendingPathComponent("database.xdb")
    try compressed.write(to: input)
    let asset = GeographyAsset(
      name: "test.xdb", file: "source.lzfse", bytes: raw.count,
      sha256: GeographyAsset.hash(raw), compressedBytes: compressed.count,
      compressedSHA256: GeographyAsset.hash(compressed))
    try IPRegionManifest.unpack(asset, from: input, to: output)
    #expect(try Data(contentsOf: output) == raw)
    for mutation in 0..<4 {
      var changed = asset
      switch mutation {
      case 0: changed.bytes = raw.count - 1
      case 1: changed.sha256 = String(repeating: "a", count: 64)
      case 2: try Data(compressed.dropLast()).write(to: input)
      default: try Data(repeating: 0, count: compressed.count).write(to: input)
      }
      #expect(throws: (any Error).self) {
        try IPRegionManifest.unpack(changed, from: input, to: output)
      }
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_IP2REGION_CDN_SMOKE"] == "1"))
  func publishedCDNDownloadsAndReopensOffline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = IPRegionDatabase(root: root)
    try await database.prepare { _ in }
    let result = try await database.resolve(["223.5.5.5", "2400:3200::1"])
    #expect(result["223.5.5.5"]?.mapKey == "CN|浙江|杭州")
    #expect(result["2400:3200::1"] == result["223.5.5.5"])
    let cached = IPRegionDatabase(
      root: root,
      manifestDownload: { _, _, _ in throw URLError(.notConnectedToInternet) },
      download: { _, _, _, _ in throw URLError(.notConnectedToInternet) })
    try await cached.prepare { _ in }
    #expect(try await cached.resolve(["223.5.5.5"])["223.5.5.5"] == result["223.5.5.5"])
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path) == [IPRegionDatabase.version])
    #expect(
      Set(
        try FileManager.default.contentsOfDirectory(
          atPath: root.appendingPathComponent(IPRegionDatabase.version).path))
        == Set(IPRegionDatabase.assets.map(\.name)))
  }

  private func manifestData() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "version": IPRegionDatabase.version,
      "files": IPRegionDatabase.assets.map { asset in
        [
          "name": asset.name, "bytes": asset.bytes, "sha256": asset.digest,
          "file": asset.name.replacingOccurrences(of: ".xdb", with: "-")
            + String(repeating: "b", count: 64) + ".lzfse",
          "compressedBytes": 64, "compressedSHA256": String(repeating: "b", count: 64),
        ] as [String: Any]
      },
    ])
  }
}
