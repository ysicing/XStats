// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

struct IPRegionDatabaseTests {
  private func fixture(family: Int, corruptPointer: Bool = false) throws -> URL {
    let width = family == 4 ? 4 : 16
    let pointer = 256 + 65536 * 8
    let region = Data("中国|浙江省|杭州市|阿里|CN".utf8)
    let first = pointer + region.count
    var data = Data(count: first + width * 2 + 6)
    put(3, at: 0, width: 2, into: &data)
    put(family, at: 16, width: 2, into: &data)
    put(4, at: 18, width: 2, into: &data)
    put(first, at: 8, width: 4, into: &data)
    put(first, at: 12, width: 4, into: &data)
    let bytes = IPRegionDatabase.publicBytes(family == 4 ? "223.5.5.5" : "2400:3200::1")!
    let vector = 256 + (Int(bytes[0]) * 256 + Int(bytes[1])) * 8
    put(first, at: vector, width: 4, into: &data)
    put(first, at: vector + 4, width: 4, into: &data)
    data.replaceSubrange(pointer..<first, with: region)
    let encoded = family == 4 ? Array(bytes.reversed()) : bytes
    data.replaceSubrange(first..<(first + width), with: encoded)
    data.replaceSubrange((first + width)..<(first + width * 2), with: encoded)
    put(region.count, at: first + width * 2, width: 2, into: &data)
    put(corruptPointer ? data.count + 1 : pointer, at: first + width * 2 + 2, width: 4, into: &data)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xdb-\(UUID()).xdb")
    try data.write(to: url)
    return url
  }

  private func put(_ value: Int, at offset: Int, width: Int, into data: inout Data) {
    for byte in 0..<width { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
  }

  @Test(arguments: [4, 6])
  func randomFileReadsRespectBothByteOrdersAndExactRangeBoundaries(_ family: Int) throws {
    let url = try fixture(family: family)
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = try XDBFile(url: url, family: family)
    let ip = family == 4 ? "223.5.5.5" : "2400:3200::1"
    let bytes = try #require(IPRegionDatabase.publicBytes(ip))
    #expect(try reader.search(bytes) == "中国|浙江省|杭州市|阿里|CN")
    var outside = bytes
    outside[outside.count - 1] += 1
    #expect(try reader.search(outside) == nil)
    if family == 4 {
      #expect(try reader.search(IPRegionDatabase.publicBytes("8.8.8.8")!) == nil)
    }
  }

  @Test func malformedPointersAndHeadersFailWithoutReadingUnboundedData() throws {
    let url = try fixture(family: 4, corruptPointer: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = try XDBFile(url: url, family: 4)
    #expect(throws: (any Error).self) {
      try reader.search(IPRegionDatabase.publicBytes("223.5.5.5")!)
    }
    try Data(repeating: 0, count: 128).write(to: url)
    #expect(throws: (any Error).self) { try XDBFile(url: url, family: 4) }
  }

  @Test func ignoresNonPublicAddressesAndNormalizesMappedIPv4() {
    for address in [
      "127.0.0.1", "10.0.0.1", "198.18.1.1", "192.0.2.1", "::1",
      "fc00::1", "fe80::1", "2001:db8::1", "::ffff:192.168.1.1", "invalid",
    ] {
      #expect(IPRegionDatabase.publicBytes(address) == nil)
    }
    #expect(
      IPRegionDatabase.publicBytes("::ffff:223.5.5.5")
        == IPRegionDatabase.publicBytes("223.5.5.5"))
  }

  @Test func cityCoordinatesAreSmallAndProvinceFallbackDoesNotInventACity() throws {
    #expect(NetworkCityCoordinates.points.count < 4096)
    let city = try #require(NetworkIPLocation.parse("中国|浙江省|杭州市|阿里|CN"))
    #expect(city.province == "浙江省" && city.city == "杭州市" && city.provider == "阿里")
    #expect(city.mapKey == "CN|浙江|杭州")
    #expect(city.longitude == 120.16142)
    let province = try #require(NetworkIPLocation.parse("中国|浙江省|不存在市|0|CN"))
    #expect(province.mapKey == "CN|浙江|")
    #expect(province.city == "不存在市" && province.provider.isEmpty)
    #expect(NetworkIPLocation.parse("中国|台湾省|台北市|0|CN") == nil)
    #expect(NetworkIPLocation.parse("Australia|Queensland|Brisbane|0|AU") == nil)
    #expect(NetworkIPLocation.parse("中国|0|0|0|CN")?.mapKey == nil)
  }

  @Test func failedDownloadDoesNotPublishOrLeavePartialFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("region-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = IPRegionDatabase(
      root: root, manifestDownload: { _, _, _ in try Self.invalidDownloadManifest() }
    ) { _, _, destination, _ in
      try Data(repeating: 0, count: 64).write(to: destination)
    }
    await #expect(throws: (any Error).self) { try await database.prepare { _ in } }
    #expect(await !database.isReady)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test func cancellationAfterAFileDownloadDoesNotPublishOrLeakStaging() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("region-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = IPRegionDatabase(
      root: root, manifestDownload: { _, _, _ in try Self.invalidDownloadManifest() }
    ) { _, _, destination, _ in
      try Data(repeating: 0, count: 64).write(to: destination)
      withUnsafeCurrentTask { $0?.cancel() }
    }
    let operation = Task { try await database.prepare { _ in } }
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(await !database.isReady)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  /// 本地验证可注入官方原库；CI 的常规用例只用最小格式夹具。
  @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_IP2REGION_FIXTURES"] != nil))
  func overlappingPreparationKeepsBothStagingDirectoriesAlive() async throws {
    let source = try #require(ProcessInfo.processInfo.environment["XSTATS_IP2REGION_FIXTURES"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("region-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = RegionPreparationGate()
    let database = IPRegionDatabase(
      root: root,
      manifestDownload: { _, _, _ in
        try Data(contentsOf: URL(fileURLWithPath: source).appendingPathComponent("current.json"))
      }
    ) { url, _, destination, _ in
      if url.lastPathComponent.hasPrefix("ip2region_v4-") { await gate.arrive() }
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: source).appendingPathComponent(
          url.lastPathComponent),
        to: destination)
    }
    async let first: Void = database.prepare { _ in }
    async let second: Void = database.prepare { _ in }
    _ = try await (first, second)
    #expect(await database.isReady)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path) == [IPRegionDatabase.version])
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_IP2REGION_FIXTURES"] != nil))
  func officialDatabasesWarmOfflineAndKeepABoundedCache() async throws {
    let source = try #require(ProcessInfo.processInfo.environment["XSTATS_IP2REGION_FIXTURES"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("region-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = IPRegionDatabase(
      root: root,
      manifestDownload: { _, _, _ in
        try Data(contentsOf: URL(fileURLWithPath: source).appendingPathComponent("current.json"))
      }
    ) { url, _, destination, _ in
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: source).appendingPathComponent(
          url.lastPathComponent),
        to: destination)
    }
    try await database.prepare { _ in }
    let addresses = ["223.5.5.5", "2400:3200::1", "::ffff:223.5.5.5", "1.1.1.1"]
    let result = try await database.resolve(addresses)
    #expect(result["223.5.5.5"]?.mapKey == "CN|浙江|杭州")
    #expect(result["2400:3200::1"] == result["223.5.5.5"])
    #expect(result["::ffff:223.5.5.5"] == result["223.5.5.5"])
    #expect(result["1.1.1.1"]?.province.isEmpty == true)
    let warm = IPRegionDatabase(
      root: root,
      manifestDownload: { _, _, _ in
        Issue.record("A valid pinned cache must not download a manifest")
        throw CocoaError(.fileReadUnknown)
      },
      download: { _, _, _, _ in
        Issue.record("A valid pinned cache must not download a database")
        throw CocoaError(.fileReadUnknown)
      })
    try await warm.prepare { _ in }
    #expect(try await warm.resolve(addresses) == result)
    let many = (0..<4096).map { "223.5.\($0 / 256).\($0 % 256)" }
    let clock = ContinuousClock()
    let duration = try await clock.measure { _ = try await warm.resolve(many) }
    #expect(await warm.cachedCount <= IPRegionDatabase.maximumCacheCount)
    print("ip2region 4096 file queries: \(duration); result cache: \(await warm.cachedCount)")
  }

  private static func invalidDownloadManifest() throws -> Data {
    let digest = GeographyAsset.hash(Data(repeating: 0, count: 64))
    return try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "version": IPRegionDatabase.version,
      "files": IPRegionDatabase.assets.map { asset in
        [
          "name": asset.name, "bytes": asset.bytes, "sha256": asset.digest,
          "file": asset.name.replacingOccurrences(of: ".xdb", with: "-") + digest + ".lzfse",
          "compressedBytes": 64, "compressedSHA256": digest,
        ] as [String: Any]
      },
    ])
  }
}

private actor RegionPreparationGate {
  private var waiting: CheckedContinuation<Void, Never>?

  func arrive() async {
    if let waiting {
      self.waiting = nil
      waiting.resume()
    } else {
      await withCheckedContinuation { waiting = $0 }
    }
  }
}
