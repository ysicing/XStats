// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network
import OSLog

public struct IPGeolocation: Codable, Sendable, Equatable {
  public let country: String
  public let countryCode: String
  public let region: String
  public let city: String
  public let isp: String
  public let domain: String
  public var org: String? = nil

  public var providerName: String {
    let name = org?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? isp : name
  }
}

/// 任意公网 IP 的归属查询；与依赖请求出口的 cleanip 查询分开缓存。
public actor IPGeolocationLookup {
  public static let shared = IPGeolocationLookup(
    cacheURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("XStats/ip-geolocation.json"),
    request: fetch)

  static let lifetime: TimeInterval = 7 * 86_400
  static let capacity = 256
  private struct Entry: Codable {
    let value: IPGeolocation
    let fetchedAt: Date
  }
  private let cacheURL: URL?
  private let now: @Sendable () -> Date
  private let request: @Sendable (URL) async throws -> Data
  private var entries: [String: Entry] = [:]
  private var loaded = false
  private var requestFailed = false
  private var writeFailed = false
  private let logger = Logger(subsystem: "work.12306.xstats", category: "IPGeolocation")

  init(
    cacheURL: URL?, now: @escaping @Sendable () -> Date = { Date() },
    request: @escaping @Sendable (URL) async throws -> Data
  ) {
    self.cacheURL = cacheURL
    self.now = now
    self.request = request
  }

  public func lookup(_ address: String) async -> IPGeolocation? {
    guard !Task.isCancelled, let key = Self.publicAddress(address) else { return nil }
    load()
    guard !Task.isCancelled else { return nil }
    let previous = entries[key]
    if let previous, (0..<Self.lifetime).contains(now().timeIntervalSince(previous.fetchedAt)) {
      return previous.value
    }
    do {
      let data = try await request(URL(string: "https://ipwho.is/\(key)")!)
      try Task.checkCancellation()
      let value = try Self.decode(data, address: key)
      try Task.checkCancellation()
      // 仅成功刷新推进时间戳；失败时保留旧记录，下一次按需查询仍可重试。
      entries[key] = Entry(value: value, fetchedAt: now())
      trim()
      save()
      if requestFailed {
        logger.notice("IP geolocation requests recovered")
        requestFailed = false
      }
      return value
    } catch {
      guard !Task.isCancelled, !(error is CancellationError) else { return nil }
      if !requestFailed {
        logger.notice("IP geolocation unavailable; retaining cached data")
        requestFailed = true
      }
      return previous?.value
    }
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    guard let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) else { return }
    do {
      let file = try FileHandle(forReadingFrom: cacheURL)
      defer { try? file.close() }
      let data = try file.read(upToCount: 2_097_153) ?? Data()
      guard data.count <= 2_097_152 else { throw NetworkLeakTest.Failure.invalidResponse }
      entries = try JSONDecoder().decode([String: Entry].self, from: data)
      trim()
    } catch {
      logger.notice("IP geolocation cache could not be read")
    }
  }

  private func trim() {
    guard entries.count > Self.capacity else { return }
    let retained = entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(Self.capacity)
    entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
  }

  private func save() {
    guard let cacheURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(entries).write(to: cacheURL, options: .atomic)
      if writeFailed {
        logger.notice("IP geolocation cache writes recovered")
        writeFailed = false
      }
    } catch {
      if !writeFailed {
        logger.error("IP geolocation cache could not be saved")
        writeFailed = true
      }
    }
  }

  private static func publicAddress(_ address: String) -> String? {
    if let ip = IPv4Address(address) {
      let bytes = Array(ip.rawValue)
      guard ![0, 10, 127].contains(bytes[0]), bytes[0] < 224,
        !(bytes[0] == 169 && bytes[1] == 254),
        !(bytes[0] == 172 && (16...31).contains(bytes[1])),
        !(bytes[0] == 192 && bytes[1] == 168)
      else { return nil }
      return ip.debugDescription
    }
    if let ip = IPv6Address(address) {
      let bytes = Array(ip.rawValue)
      // 仅全球单播；不将本地、链路本地、组播或 IPv4 映射地址发给第三方。
      guard bytes[0] & 0xE0 == 0x20 else { return nil }
      return ip.debugDescription
    }
    return nil
  }

  static func decode(_ data: Data, address: String) throws -> IPGeolocation {
    struct Response: Decodable {
      struct Connection: Decodable {
        let isp: String?
        let domain: String?
        let org: String?
      }
      let success: Bool
      let ip: String
      let country: String?
      let country_code: String?
      let region: String?
      let city: String?
      let connection: Connection?
    }
    guard data.count <= 65_536 else { throw NetworkLeakTest.Failure.invalidResponse }
    let response = try JSONDecoder().decode(Response.self, from: data)
    guard response.success, let key = publicAddress(address),
      publicAddress(response.ip) == key
    else { throw NetworkLeakTest.Failure.invalidResponse }
    let code = clean(response.country_code).uppercased()
    return IPGeolocation(
      country: clean(response.country),
      countryCode: code.utf8.count == 2 && code.utf8.allSatisfy({ (65...90).contains($0) })
        ? code : "",
      region: clean(response.region), city: clean(response.city),
      isp: clean(response.connection?.isp), domain: clean(response.connection?.domain),
      org: clean(response.connection?.org))
  }

  private static func clean(_ value: String?) -> String {
    String((value ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
      .trimmingCharacters(in: .whitespacesAndNewlines).prefix(253).description
  }

  private static func fetch(_ url: URL) async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 8
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpShouldSetCookies = false
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(from: url)
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      response.expectedContentLength <= 65_536
    else { throw NetworkLeakTest.Failure.invalidResponse }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < 65_536 else { throw NetworkLeakTest.Failure.invalidResponse }
      data.append(byte)
    }
    return data
  }
}
