// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

public enum DNSBenchmarkProtocol: String, CaseIterable, Sendable, Identifiable {
  case udp = "UDP"
  case tcp = "TCP"
  case dot = "DoT"
  case doh = "DoH"
  public var id: String { rawValue }
}

public struct DNSBenchmarkTarget: Identifiable, Hashable, Sendable {
  public let name: String
  public let host: String
  public let transport: DNSBenchmarkProtocol
  public let port: UInt16
  public let tlsServerName: String?
  public let httpsURL: URL?
  public let isSystem: Bool
  public let providerID: String

  public var id: String {
    if transport == .doh, let httpsURL { return "\(transport.rawValue)|\(httpsURL.absoluteString)" }
    return
      "\(transport.rawValue)|\(host)|\(port)|\(tlsServerName ?? "")|\(httpsURL?.absoluteString ?? "")"
  }

  public init(
    name: String, host: String, transport: DNSBenchmarkProtocol, port: UInt16? = nil,
    tlsServerName: String? = nil, httpsURL: URL? = nil, isSystem: Bool = false,
    providerID: String? = nil
  ) {
    self.name = name
    self.host = host
    self.transport = transport
    self.port = port ?? (transport == .dot ? 853 : transport == .doh ? 443 : 53)
    self.tlsServerName = tlsServerName
    self.httpsURL = httpsURL
    self.isSystem = isSystem
    self.providerID = providerID ?? name
  }

  public static func custom(_ input: String, transport: DNSBenchmarkProtocol) -> Self? {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty, input.utf8.count <= 2048 else { return nil }
    let scheme =
      transport == .doh ? "https" : transport == .dot ? "tls" : transport.rawValue.lowercased()
    var address = input
    var ipv6 = in6_addr()
    if inet_pton(AF_INET6, input, &ipv6) == 1 { address = "[\(input)]" }
    guard
      let components = URLComponents(
        string: address.contains("://") ? address : "\(scheme)://\(address)"),
      components.scheme == scheme, components.user == nil, components.password == nil,
      components.fragment == nil, let rawHost = components.host
    else { return nil }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if rawHost.hasPrefix("[") && inet_pton(AF_INET6, host, &ipv6) != 1 { return nil }
    guard !host.isEmpty,
      let port = UInt16(
        exactly: components.port ?? (transport == .dot ? 853 : transport == .doh ? 443 : 53)),
      port > 0
    else { return nil }
    if transport == .udp || transport == .tcp {
      var ipv4 = in_addr()
      guard inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1 else {
        return nil
      }
    } else {
      var ipv4 = in_addr()
      guard
        inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
          || (try? DNSBenchmarkWire.query(domain: host, id: 0)) != nil
      else { return nil }
    }
    guard transport == .doh || (components.path.isEmpty && components.query == nil) else {
      return nil
    }
    var https = components
    if transport == .doh && https.path.isEmpty { https.path = "/dns-query" }
    return Self(
      name: host, host: host, transport: transport, port: port,
      tlsServerName: transport == .dot ? host : nil,
      httpsURL: transport == .doh ? https.url : nil,
      providerID:
        "custom|\(transport == .doh ? https.url?.absoluteString ?? input : "\(host)|\(port)")")
  }

  public static func defaults(
    transport: DNSBenchmarkProtocol, systemServers: [String]
  ) -> [Self] {
    let providers: [(String, String, String?, String?)] = [
      ("AliDNS", "223.5.5.5", "dns.alidns.com", "https://dns.alidns.com/dns-query"),
      ("DNSPod", "119.29.29.29", "dot.pub", "https://doh.pub/dns-query"),
      ("114DNS", "114.114.114.114", nil, nil),
      ("360 DNS", "101.226.4.6", "dot.360.cn", "https://doh.360.cn/dns-query"),
      ("Baidu", "180.76.76.76", nil, nil),
      ("Cloudflare", "1.1.1.1", "one.one.one.one", "https://cloudflare-dns.com/dns-query"),
      ("Google", "8.8.8.8", "dns.google", "https://dns.google/dns-query"),
      ("Quad9", "9.9.9.9", "dns.quad9.net", "https://dns.quad9.net/dns-query"),
      ("AdGuard", "94.140.14.14", "dns.adguard-dns.com", "https://dns.adguard-dns.com/dns-query"),
      ("OpenDNS", "208.67.222.222", "dns.opendns.com", "https://dns.opendns.com/dns-query"),
    ]
    var targets: [Self] = []
    if transport == .udp || transport == .tcp {
      // 36 个内置协议端点，加上 12 个系统端点及 16 个自定义端点，不超过 64 个总额。
      for address in systemServers.prefix(6) {
        guard let target = custom(address, transport: transport),
          !targets.contains(where: { $0.id == target.id })
        else { continue }
        targets.append(
          Self(
            name: target.port == 53
              ? providers.first { $0.1 == target.host }?.0 ?? address : address,
            host: target.host, transport: transport, port: target.port,
            isSystem: true,
            providerID: target.port == 53
              ? providers.first { $0.1 == target.host }.map { "public|\($0.0)" }
                ?? "system|\(target.host)|\(target.port)"
              : "system|\(target.host)|\(target.port)"))
      }
    }
    for (name, address, tls, https) in providers {
      if transport == .dot && tls == nil || transport == .doh && https == nil { continue }
      let target = Self(
        name: name, host: address, transport: transport,
        tlsServerName: transport == .dot ? tls : nil,
        httpsURL: transport == .doh ? https.flatMap(URL.init(string:)) : nil,
        providerID: "public|\(name)")
      if !targets.contains(where: { $0.id == target.id }) { targets.append(target) }
    }
    return targets
  }
}

public enum DNSBenchmarkFailure: Error, Sendable, Equatable {
  case timeout, connection, invalidResponse, noAnswer, cancelled
}

public struct DNSBenchmarkSample: Sendable {
  public let milliseconds: Double
  public let handshakeMilliseconds: Double?
  public let addresses: [String]

  public init(
    milliseconds: Double, handshakeMilliseconds: Double? = nil, addresses: [String] = []
  ) {
    self.milliseconds = milliseconds
    self.handshakeMilliseconds = handshakeMilliseconds
    self.addresses = addresses
  }
}

public struct DNSBenchmarkResult: Identifiable, Sendable {
  public let target: DNSBenchmarkTarget
  public private(set) var samples: [Double] = []
  public private(set) var attempts = 0
  public private(set) var handshakeMilliseconds: Double?
  public private(set) var firstQueryMilliseconds: Double?
  public private(set) var addresses: [String] = []
  public private(set) var lastFailure: DNSBenchmarkFailure?
  public var intercepted = false
  public var id: String { target.id }
  public var median: Double? {
    guard !samples.isEmpty else { return nil }
    let sorted = samples.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }
  public var p90: Double? {
    guard !samples.isEmpty else { return nil }
    return samples.sorted()[max(0, Int(ceil(Double(samples.count) * 0.9)) - 1)]
  }
  public var failureRate: Double {
    attempts == 0 ? 0 : Double(attempts - samples.count) / Double(attempts)
  }
  public var score: Double? {
    guard !intercepted, let median else { return nil }
    return median * (1 + failureRate * 3)
  }

  public init(target: DNSBenchmarkTarget) { self.target = target }

  public mutating func recordFirstQuery(milliseconds: Double) {
    guard firstQueryMilliseconds == nil, milliseconds.isFinite, milliseconds >= 0 else { return }
    firstQueryMilliseconds = milliseconds
  }

  public mutating func record(_ outcome: Result<DNSBenchmarkSample, DNSBenchmarkFailure>) {
    guard attempts < 20 else { return }
    attempts += 1
    switch outcome {
    case .success(let sample):
      guard sample.milliseconds.isFinite, sample.milliseconds >= 0 else {
        lastFailure = .invalidResponse
        return
      }
      samples.append(sample.milliseconds)
      if let handshake = sample.handshakeMilliseconds { handshakeMilliseconds = handshake }
      addresses = Array(sample.addresses.prefix(16))
      lastFailure = nil
    case .failure(let failure): lastFailure = failure
    }
  }
}
