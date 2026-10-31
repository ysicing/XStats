// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Darwin
import Foundation
import OSLog

struct NetworkIPLocation: Codable, Sendable, Equatable {
  var province = ""
  var city = ""
  var provider = ""
  var longitude: Double?
  var latitude: Double?

  var placeKey: String? {
    guard !province.isEmpty, longitude != nil, latitude != nil else { return nil }
    return "CN|\(Self.normalizedProvince(province))|\(Self.normalizedCity(city))"
  }

  var displayName: String {
    var parts = [province]
    if city != province { parts.append(city) }
    parts.append(provider)
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  static func normalizedProvince(_ value: String) -> String {
    var value = value
    for suffix in ["壮族自治区", "回族自治区", "维吾尔自治区", "自治区", "省", "市"]
    where value.hasSuffix(suffix) {
      value.removeLast(suffix.count)
      break
    }
    return value
  }

  static func normalizedCity(_ value: String) -> String {
    value.hasSuffix("市") ? String(value.dropLast()) : value
  }

  /// 固定版本 XDB 使用 country|province|city|ISP|ISO；港澳台沿用国家/地域库。
  static func parse(
    _ region: String, coordinates: [String: [Double]] = NetworkCityCoordinates.points
  ) -> Self? {
    let fields = region.components(separatedBy: "|")
    guard fields.count == 5, fields[0] == "中国", fields[4] == "CN",
      !["台湾省", "香港特别行政区", "澳门特别行政区"].contains(fields[1]),
      fields.allSatisfy({ $0.utf8.count <= 256 && !$0.contains("\n") })
    else { return nil }
    let province = fields[1] == "0" ? "" : fields[1]
    let city = fields[2] == "0" ? "" : fields[2]
    let provider = fields[3] == "0" ? "" : fields[3]
    let prefix = normalizedProvince(province) + "|"
    let exact = coordinates[prefix + normalizedCity(city)]
    let point = exact ?? coordinates[prefix]
    // 没有城市坐标时以省级聚合；列表仍保留原始省市名称。
    return Self(
      province: province, city: city, provider: provider,
      longitude: point?.first, latitude: point?.count == 2 ? point?[1] : nil)
  }

  var mapKey: String? {
    guard let placeKey else { return nil }
    let exact = NetworkCityCoordinates.points[
      Self.normalizedProvince(province) + "|" + Self.normalizedCity(city)]
    return exact == nil ? "CN|\(Self.normalizedProvince(province))|" : placeKey
  }
}

enum NetworkCityCoordinates {
  static let points: [String: [Double]] = {
    guard
      let url = Bundle.module.url(
        forResource: "china-cities", withExtension: "json", subdirectory: "NetworkGeography"),
      let data = try? Data(contentsOf: url), data.count <= 512 * 1024,
      let points = try? JSONDecoder().decode([String: [Double]].self, from: data),
      points.count <= 4096
    else { return [:] }
    return points.filter {
      $0.value.count == 2 && $0.value[0].isFinite && $0.value[1].isFinite
        && (-180...180).contains($0.value[0]) && (-90...90).contains($0.value[1])
    }
  }()
}

/// 串行文件查询：两个文件句柄、最多 1024 个结果，不常驻整库或 512 KiB 向量表。
actor IPRegionDatabase {
  static let shared = IPRegionDatabase()
  static let version = "6a276cc7c4f9f2d7ff1d8ace14b91af59752f943"
  static let maximumCacheCount = 1024
  struct Asset: Sendable {
    let family: Int
    let bytes: Int
    let digest: String
    var name: String { "ip2region_v\(family).xdb" }
  }
  static let assets = [
    Asset(
      family: 4, bytes: 11_122_714,
      digest: "46249ad1b33bcaa4cc37475b93746cec2b00acffc3316cc4f56167ac821ea2ad"),
    Asset(
      family: 6, bytes: 37_277_813,
      digest: "939f6b46bd2b8bec3cf7c5ceb8ba782266ae9b1f35b5ba7916700dec0b7506ed"),
  ]
  typealias Download =
    @Sendable (
      URL, Int, URL, @escaping @Sendable (Double) -> Void
    ) async throws -> Void
  private static let log = Logger(subsystem: "work.12306.xstats", category: "network-geography")
  private let root: URL
  private let manifestDownload: OfflineGeography.Download
  private let download: Download
  private var readers: [Int: XDBFile] = [:]
  private var cache: [String: NetworkIPLocation] = [:]
  private var activeStaging: Set<String> = []
  private var didLoad = false
  var isReady: Bool { readers.count == 2 }
  var cachedCount: Int { cache.count }

  init(
    root: URL? = nil, manifestDownload: @escaping OfflineGeography.Download = downloadGeography,
    download: @escaping Download = downloadGeographyFile
  ) {
    self.root =
      root
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("XStats/NetworkGeography/ip2region", isDirectory: true)
    self.manifestDownload = manifestDownload
    self.download = download
  }

  func loadCached() -> Bool {
    if didLoad { return isReady }
    didLoad = true
    do {
      readers = try openPair(root.appendingPathComponent(Self.version))
      removeOlderDirectories()
    } catch {
      readers = [:]
    }
    return isReady
  }

  func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
    if loadCached() { return }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    removeOlderDirectories()
    let staging = root.appendingPathComponent(UUID().uuidString + ".partial", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    // 以目录名识别，避免 macOS 的 /var 与 /private/var 路径别名误删活动下载。
    activeStaging.insert(staging.lastPathComponent)
    defer {
      activeStaging.remove(staging.lastPathComponent)
      try? FileManager.default.removeItem(at: staging)
    }
    do {
      let data = try await manifestDownload(
        IPRegionManifest.baseURL.appendingPathComponent("current.json"), 64 * 1024, { _ in })
      try Task.checkCancellation()
      let manifest = try IPRegionManifest.decode(data)
      let total = manifest.files.reduce(0) { $0 + $1.compressedBytes }
      var completed = 0
      for asset in manifest.files {
        try Task.checkCancellation()
        let base = completed
        let compressed = staging.appendingPathComponent(asset.file)
        try await download(
          IPRegionManifest.baseURL.appendingPathComponent(asset.file),
          asset.compressedBytes, compressed
        ) {
          progress((Double(base) + $0 * Double(asset.compressedBytes)) / Double(total))
        }
        try Task.checkCancellation()
        try IPRegionManifest.unpack(
          asset, from: compressed, to: staging.appendingPathComponent(asset.name))
        try FileManager.default.removeItem(at: compressed)
        completed += asset.compressedBytes
      }
      try Task.checkCancellation()
      if isReady { return }
      // 两库均通过长度、SHA256 和头部校验后才替换；取消/失败保留原有数据。
      let pair = try openPair(staging)
      try Task.checkCancellation()
      let destination = root.appendingPathComponent(Self.version, isDirectory: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: staging, to: destination)
      readers = pair
      cache.removeAll(keepingCapacity: false)
      Self.log.info("ip2region offline databases ready")
      progress(1)
      // 只清理本模块的旧固定版本目录，无后台更新或清理定时器。
      removeOlderDirectories()
    } catch {
      Self.log.error(
        "ip2region preparation failed: \(String(describing: error), privacy: .private)")
      throw error
    }
  }

  private func removeOlderDirectories() {
    let items =
      (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)) ?? []
    for item in items where item.lastPathComponent != Self.version {
      let name = item.lastPathComponent
      let isVersion =
        name.count == 40
        && name.utf8.allSatisfy {
          (48...57).contains($0) || (97...102).contains($0)
        }
      if (isVersion || name.hasSuffix(".partial")) && !activeStaging.contains(name) {
        try? FileManager.default.removeItem(at: item)
      }
    }
  }

  func resolve(_ addresses: [String]) throws -> [String: NetworkIPLocation] {
    _ = loadCached()
    guard isReady else { return [:] }
    var result: [String: NetworkIPLocation] = [:]
    for address in Set(addresses) {
      try Task.checkCancellation()
      if let cached = cache[address] {
        result[address] = cached
        continue
      }
      guard let bytes = Self.publicBytes(address) else { continue }
      let region = try readers[bytes.count == 4 ? 4 : 6]?.search(bytes)
      let location = region.flatMap { NetworkIPLocation.parse($0) } ?? NetworkIPLocation()
      // 小型批次淘汰，避免维护额外的每-IP LRU 链；空结果也缓存。
      if cache.count >= Self.maximumCacheCount { cache.removeAll(keepingCapacity: true) }
      cache[address] = location
      result[address] = location
    }
    return result
  }

  private func openPair(_ directory: URL) throws -> [Int: XDBFile] {
    var result: [Int: XDBFile] = [:]
    for asset in Self.assets {
      try Task.checkCancellation()
      let url = directory.appendingPathComponent(asset.name)
      guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.bytes else {
        throw CocoaError(.coderReadCorrupt)
      }
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      var hash = SHA256()
      while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
        try Task.checkCancellation()
        hash.update(data: chunk)
      }
      guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.digest else {
        throw CocoaError(.coderReadCorrupt)
      }
      result[asset.family] = try XDBFile(url: url, family: asset.family)
    }
    return result
  }

  static func publicBytes(_ address: String) -> [UInt8]? {
    var v4 = in_addr()
    if inet_pton(AF_INET, address, &v4) == 1 {
      let bytes = withUnsafeBytes(of: v4) { Array($0) }
      return OfflineGeography.isLocalV4(bytes) ? nil : bytes
    }
    var v6 = in6_addr()
    guard inet_pton(AF_INET6, address, &v6) == 1 else { return nil }
    let bytes = withUnsafeBytes(of: v6) { Array($0) }
    if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
      let mapped = Array(bytes.suffix(4))
      return OfflineGeography.isLocalV4(mapped) ? nil : mapped
    }
    guard bytes[0] & 0xe0 == 0x20, Array(bytes.prefix(4)) != [0x20, 0x01, 0x0d, 0xb8] else {
      return nil
    }
    return bytes
  }
}

/// 参照官方 XDB 3.0 格式独立实现；所有指针、记录宽度和字符串长度在读取前校验。
final class XDBFile {
  private let handle: FileHandle
  private let size: Int
  private let width: Int
  private let first: Int
  private let last: Int
  private var stride: Int { width * 2 + 6 }

  init(url: URL, family: Int) throws {
    guard family == 4 || family == 6 else { throw CocoaError(.coderReadCorrupt) }
    let handle = try FileHandle(forReadingFrom: url)
    do {
      let size = Int(try handle.seekToEnd())
      guard size >= 256 + 65536 * 8, size <= 64 * 1024 * 1024 else {
        throw CocoaError(.coderReadCorrupt)
      }
      try handle.seek(toOffset: 0)
      let header = try handle.read(upToCount: 256) ?? Data()
      guard header.count == 256, Self.integer(header, 0, 2) == 3,
        Self.integer(header, 16, 2) == family, Self.integer(header, 18, 2) == 4
      else { throw CocoaError(.coderReadCorrupt) }
      let first = Self.integer(header, 8, 4)
      let last = Self.integer(header, 12, 4)
      let width = family == 4 ? 4 : 16
      let stride = width * 2 + 6
      guard first >= 256 + 65536 * 8, last >= first, last <= size - stride,
        (last - first) % stride == 0
      else { throw CocoaError(.coderReadCorrupt) }
      self.handle = handle
      self.size = size
      self.width = width
      self.first = first
      self.last = last
    } catch {
      try? handle.close()
      throw error
    }
  }

  deinit { try? handle.close() }

  func search(_ bytes: [UInt8]) throws -> String? {
    guard bytes.count == width else { throw CocoaError(.coderReadCorrupt) }
    let vector = try read(256 + (Int(bytes[0]) * 256 + Int(bytes[1])) * 8, count: 8)
    let start = Self.integer(vector, 0, 4)
    let end = Self.integer(vector, 4, 4)
    if start == 0 && end == 0 { return nil }
    guard start >= first, end >= start, end <= last,
      (start - first) % stride == 0, (end - start) % stride == 0
    else { throw CocoaError(.coderReadCorrupt) }
    var low = 0
    var high = (end - start) / stride
    while low <= high {
      let middle = (low + high) / 2
      let segment = try read(start + middle * stride, count: stride)
      let a = Array(segment.prefix(width))
      let b = Array(segment.dropFirst(width).prefix(width))
      let lower = width == 4 ? Array(a.reversed()) : a
      let upper = width == 4 ? Array(b.reversed()) : b
      if bytes.lexicographicallyPrecedes(lower) {
        high = middle - 1
      } else if upper.lexicographicallyPrecedes(bytes) {
        low = middle + 1
      } else {
        let length = Self.integer(segment, width * 2, 2)
        let pointer = Self.integer(segment, width * 2 + 2, 4)
        if length == 0 { return nil }
        guard length <= 1024, pointer >= 256 + 65536 * 8, pointer <= first - length,
          let value = String(data: try read(pointer, count: length), encoding: .utf8)
        else { throw CocoaError(.coderReadCorrupt) }
        return value
      }
    }
    return nil
  }

  private func read(_ offset: Int, count: Int) throws -> Data {
    guard offset >= 0, count > 0, count <= 1024, offset <= size - count else {
      throw CocoaError(.coderReadCorrupt)
    }
    try handle.seek(toOffset: UInt64(offset))
    let result = try handle.read(upToCount: count) ?? Data()
    guard result.count == count else { throw CocoaError(.coderReadCorrupt) }
    return result
  }

  private static func integer(_ data: Data, _ offset: Int, _ count: Int) -> Int {
    (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
  }
}
