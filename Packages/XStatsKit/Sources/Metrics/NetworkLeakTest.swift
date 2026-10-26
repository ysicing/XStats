// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network

/// 按需检测当前请求路径；观察到的地址不是 VPN 是否泄漏的自动判决。
public enum NetworkLeakTest {
  public enum Failure: Error, Sendable { case invalidResponse, unavailable }

  public struct Resolver: Sendable, Equatable, Identifiable {
    public let address: String
    public let country: String
    public let organization: String
    public var id: String { address }
  }

  public struct DNSResult: Sendable, Equatable {
    public let exits: [String]
    public let resolvers: [Resolver]
  }

  public struct Candidate: Sendable, Equatable, Identifiable {
    public let address: String
    public let kind: String
    public var id: String { "\(kind):\(address)" }
    public var isReflexive: Bool { kind == "srflx" || kind == "prflx" }
  }

  /// 按 SDP 字段解析，不能用扫描整行 IP 的正则误取 raddr 或 foundation。
  public static func candidate(_ line: String) -> Candidate? {
    guard line.utf8.count <= 2048 else { return nil }
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 8, fields[0].hasPrefix("candidate:"), fields[6] == "typ",
      ["host", "srflx", "prflx", "relay"].contains(fields[7])
    else { return nil }
    let address = String(fields[4])
    let isMDNS =
      fields[7] == "host" && address.hasSuffix(".local")
      && address.utf8.count <= 253
      && address.utf8.allSatisfy {
        $0 == 45 || $0 == 46 || (48...57).contains($0) || (65...90).contains($0)
          || (97...122).contains($0)
      }
    guard PublicAddressLookup.isAddress(address) || isMDNS else { return nil }
    return Candidate(address: address, kind: String(fields[7]))
  }

  /// 只比较相同地址族的公网候选；另一地址族和 mDNS 不能判成泄漏或安全。
  public static func matchesExit(_ candidate: Candidate, exit: String?) -> Bool? {
    guard candidate.isReflexive, let exit else { return nil }
    if let lhs = IPv4Address(candidate.address), let rhs = IPv4Address(exit) {
      return lhs.rawValue == rhs.rawValue
    }
    if let lhs = IPv6Address(candidate.address), let rhs = IPv6Address(exit) {
      return lhs.rawValue == rhs.rawValue
    }
    return nil
  }

  public static func dns() async throws -> DNSResult {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 6
    configuration.timeoutIntervalForResource = 8
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpShouldSetCookies = false
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    return try await dns { url, timeout in
      var request = URLRequest(url: url)
      request.timeoutInterval = timeout
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
        response.expectedContentLength <= 65_536
      else { throw Failure.unavailable }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < 65_536 else { throw Failure.invalidResponse }
        data.append(byte)
      }
      return data
    }
  }

  // 传输可替换，回归不访问真实服务，也不污染开发机 DNS。
  static func dns(request: @Sendable (URL, TimeInterval) async throws -> Data) async throws
    -> DNSResult
  {
    try Task.checkCancellation()
    let sessionData = try await request(URL(string: "https://bash.ws/id")!, 6)
    let token = String(decoding: sessionData, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard (1...63).contains(token.utf8.count),
      token.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
      })
    else { throw Failure.invalidResponse }
    for index in 1...3 {
      try Task.checkCancellation()
      do {
        _ = try await request(URL(string: "https://ex.\(index).\(token).bash.ws/css/z.css")!, 2)
      } catch {
        // TLS 失败仍可能已触发 DNS；以服务端观察结果为准，但取消必须立即停止后续探测。
        try Task.checkCancellation()
      }
    }
    try Task.checkCancellation()
    let data = try await request(URL(string: "https://bash.ws/dnsleak/test/\(token)?json")!, 6)
    try Task.checkCancellation()
    return try decodeDNS(data)
  }

  static func decodeDNS(_ data: Data) throws -> DNSResult {
    struct Entry: Decodable {
      let ip: String
      let type: String
      let country_name: String?
      let org: String?
      let asn: String?

      enum CodingKeys: String, CodingKey { case ip, type, country_name, org, asn }

      init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ip = try values.decode(String.self, forKey: .ip)
        type = try values.decode(String.self, forKey: .type)
        // 服务会用 false 表示未知元数据；辅助描述不可导致有效地址被整批丢弃。
        country_name = try? values.decode(String.self, forKey: .country_name)
        org = try? values.decode(String.self, forKey: .org)
        asn = try? values.decode(String.self, forKey: .asn)
      }
    }
    guard data.count <= 65_536,
      let entries = try? JSONDecoder().decode([Entry].self, from: data), entries.count <= 256
    else { throw Failure.invalidResponse }
    var exits: [String] = []
    var resolvers: [Resolver] = []
    for entry in entries {
      guard PublicAddressLookup.isAddress(entry.ip) else { continue }
      if entry.type == "ip", !exits.contains(entry.ip) { exits.append(entry.ip) }
      if entry.type == "dns", !resolvers.contains(where: { $0.address == entry.ip }) {
        resolvers.append(
          Resolver(
            address: entry.ip, country: String((entry.country_name ?? "").prefix(128)),
            organization: String((entry.org ?? entry.asn ?? "").prefix(256))))
      }
    }
    guard !resolvers.isEmpty else { throw Failure.invalidResponse }
    return DNSResult(exits: exits.sorted(), resolvers: resolvers.sorted { $0.address < $1.address })
  }
}
