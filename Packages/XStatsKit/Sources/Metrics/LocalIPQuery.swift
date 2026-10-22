// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 按来源独立查询公网出口；归属地只属于该来源实际返回的地址，不跨出口拼接。
public enum LocalIPQuery {
  public enum Source: String, CaseIterable, Sendable, Identifiable {
    case ipv4, ipv6, domestic, cloudflare, ipify, ipSB
    public var id: String { rawValue }
  }

  public enum Failure: Error, Sendable, Equatable {
    case connection
    case http(Int)
    case invalidResponse
    case cancelled
  }

  public typealias Response = Result<PublicAddresses, Failure>

  public static func fetch(_ source: Source) async -> Response {
    guard !Task.isCancelled else { return .failure(.cancelled) }
    let response: (Data?, Int)
    switch source {
    case .ipv4, .ipv6:
      response = await PublicAddressLookup.requestOwnExit(ipv6: source == .ipv6)
    case .domestic:
      response = await PublicAddressLookup.getWithStatus(EgressTarget.domestic.url)
    case .cloudflare:
      response = await PublicAddressLookup.getWithStatus(EgressTarget.cloudflare.url)
    case .ipify:
      response = await PublicAddressLookup.getWithStatus(
        URL(string: "https://api.ipify.org?format=json")!)
    case .ipSB:
      // 原生客户端直接读取 JSON，无需网页使用的 callback 包装。
      response = await PublicAddressLookup.getWithStatus(
        URL(string: "https://api.ip.sb/geoip")!)
    }
    guard !Task.isCancelled else { return .failure(.cancelled) }
    return decode(response.0, status: response.1, source: source)
  }

  static func decode(_ data: Data?, status: Int, source: Source) -> Response {
    guard status != 0 else { return .failure(.connection) }
    guard status == 200 else { return .failure(.http(status)) }
    guard let data, let result = parse(data, source: source) else {
      return .failure(.invalidResponse)
    }
    return .success(result)
  }

  static func parse(_ data: Data, source: Source) -> PublicAddresses? {
    switch source {
    case .ipv4, .ipv6:
      guard let geo = PublicAddressLookup.parseCleanIP(data), let ip = geo.ip,
        ip.contains(":") == (source == .ipv6)
      else { return nil }
      var result = PublicAddresses(
        ipv4: source == .ipv4 ? ip : nil, ipv6: source == .ipv6 ? ip : nil)
      result.apply(geo)
      return result
    case .domestic, .ipify:
      struct Echo: Decodable { let ip: String }
      guard let echo = try? JSONDecoder().decode(Echo.self, from: data) else { return nil }
      let ip = echo.ip.trimmingCharacters(in: .whitespacesAndNewlines)
      guard PublicAddressLookup.isAddress(ip) else { return nil }
      return PublicAddresses(ipv4: ip.contains(":") ? nil : ip, ipv6: ip.contains(":") ? ip : nil)
    case .cloudflare:
      let fields = PublicAddressLookup.parseTrace(String(decoding: data, as: UTF8.self))
      guard let ip = fields["ip"] else { return nil }
      return PublicAddresses(
        ipv4: ip.contains(":") ? nil : ip, ipv6: ip.contains(":") ? ip : nil,
        countryCode: fields["loc"].flatMap(PublicAddressLookup.validCountryCode))
    case .ipSB:
      struct GeoIP: Decodable {
        let ip: String
        let countryCode: String?
        let city: String?
        let region: String?
        let asn: UInt32?
        let isp: String?
        let organization: String?
        let asnOrganization: String?
      }
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      guard let geo = try? decoder.decode(GeoIP.self, from: data) else { return nil }
      let ip = geo.ip.trimmingCharacters(in: .whitespacesAndNewlines)
      guard PublicAddressLookup.isAddress(ip) else { return nil }
      let organization = [geo.isp, geo.organization, geo.asnOrganization]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
      return PublicAddresses(
        ipv4: ip.contains(":") ? nil : ip, ipv6: ip.contains(":") ? ip : nil,
        countryCode: geo.countryCode.flatMap(PublicAddressLookup.validCountryCode),
        city: geo.city, region: geo.region,
        asn: geo.asn.flatMap { $0 > 0 ? "AS\($0)" : nil }, organization: organization)
    }
  }
}
