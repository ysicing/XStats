// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Darwin
import Foundation
import Localization
import WebDAVSync

enum ActivityDAVError: LocalizedError, Equatable, Sendable {
  case invalidAddress

  var errorDescription: String? {
    tr("请输入有效的 WebDAV 目录地址。HTTP 仅支持私有局域网或 Tailscale，不允许账号、查询参数或片段。")
  }
}

struct ActivityDAVConfiguration: Equatable, Sendable {
  let directoryURL: URL
  let username: String
  let credentialAccount: String
  let endpoint: ActivityDAVEndpoint

  init(address: String, username: String) throws {
    let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.lowercased().hasPrefix("https:") {
      let existing: WebDAVConfiguration
      do {
        existing = try WebDAVConfiguration(address: address, username: username)
      } catch WebDAVError.invalidAddress {
        throw ActivityDAVError.invalidAddress
      }
      guard let origin = ActivityDAVEndpoint(existing.directoryURL) else {
        throw ActivityDAVError.invalidAddress
      }
      directoryURL = existing.directoryURL
      self.username = existing.username
      credentialAccount = existing.credentialAccount
      endpoint = origin
      return
    }

    guard text.lowercased().hasPrefix("http://"),
      !text.contains("\\"),
      !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      let parts = URLComponents(string: text),
      parts.user == nil, parts.percentEncodedPassword == nil, parts.query == nil,
      parts.fragment == nil,
      !parts.path.contains("\\"),
      !parts.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { throw ActivityDAVError.invalidAddress }

    let authority = text.dropFirst(7).prefix { !"/?#".contains($0) }
    let (host, port) = try Self.httpAuthority(authority)
    let encodedPath = parts.percentEncodedPath.lowercased()
    guard !encodedPath.contains("%2f"), !encodedPath.contains("%5c") else {
      throw ActivityDAVError.invalidAddress
    }
    guard !username.isEmpty, !username.contains(":"),
      !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw WebDAVError.invalidUsername }

    var path = parts.percentEncodedPath
    while path.hasSuffix("/") { path.removeLast() }
    let authorityPort = port.map { ":\($0)" } ?? ""
    guard
      let url = URL(
        string: "http://\(host)\(authorityPort)\(path)/",
        encodingInvalidCharacters: false),
      let origin = ActivityDAVEndpoint(url)
    else {
      throw ActivityDAVError.invalidAddress
    }
    directoryURL = url
    self.username = username
    endpoint = origin
    credentialAccount = SHA256.hash(
      data: Data("activity DAV\n\(url.absoluteString)\n\(username)".utf8)
    )
    .map { String(format: "%02x", $0) }.joined()
  }

  private static func httpAuthority(_ authority: Substring) throws -> (String, Int?) {
    let host: Substring
    let suffix: Substring
    if authority.first == "[" {
      guard let bracket = authority.firstIndex(of: "]") else {
        throw ActivityDAVError.invalidAddress
      }
      host = authority[authority.index(after: authority.startIndex)..<bracket]
      suffix = authority[authority.index(after: bracket)...]
      guard let address = ActivityDAVIPAddress(String(host)), address.family == .ipv6,
        address.network != nil
      else { throw ActivityDAVError.invalidAddress }
    } else {
      let separator = authority.firstIndex(of: ":") ?? authority.endIndex
      host = authority[..<separator]
      suffix = authority[separator...]
    }

    let port: Int?
    if suffix.isEmpty {
      port = nil
    } else {
      let digits = suffix.dropFirst()
      guard suffix.first == ":", !digits.isEmpty,
        digits.utf8.allSatisfy({ (48...57).contains($0) }),
        let value = Int(digits), (1...65_535).contains(value)
      else { throw ActivityDAVError.invalidAddress }
      port = value
    }
    if let address = ActivityDAVIPAddress(String(host)) {
      guard address.network != nil, (address.family == .ipv6) == (authority.first == "["),
        address.family != .ipv4 || host == address.text
      else {
        throw ActivityDAVError.invalidAddress
      }
      return (address.urlHost, port)
    }

    let name = host.lowercased()
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    guard host.utf8.allSatisfy({ $0 < 128 }), name.utf8.count <= 253,
      labels.allSatisfy({ label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
          && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
      })
    else { throw ActivityDAVError.invalidAddress }
    var legacy = in_addr()
    guard inet_aton(name, &legacy) == 0,
      let last = labels.last, last.utf8.contains(where: { (97...122).contains($0) })
    else { throw ActivityDAVError.invalidAddress }
    return (name, port)
  }
}

/// 这是用户配置的 WebDAV origin，用于 Host 请求头及校验列表中的 href。
struct ActivityDAVEndpoint: Equatable, Sendable {
  let scheme: String
  let host: String
  let port: Int

  init?(_ url: URL) {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
      let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.percentEncodedPassword == nil
    else { return nil }
    let bareHost =
      host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    self.scheme = scheme
    self.host = ActivityDAVIPAddress(bareHost)?.text ?? bareHost.lowercased()
    port = parts.port ?? (scheme == "http" ? 80 : 443)
  }

  var authority: String {
    let name = host.contains(":") ? "[\(host)]" : host
    return port == (scheme == "http" ? 80 : 443) ? name : "\(name):\(port)"
  }
}

struct ActivityDAVIPAddress: Hashable, Sendable {
  enum Family: Hashable, Sendable { case ipv4, ipv6 }
  enum PrivateNetwork: Hashable, Sendable { case lan, tailscale }

  let text: String
  let family: Family
  let network: PrivateNetwork?

  var urlHost: String { family == .ipv6 ? "[\(text)]" : text }

  init?(_ input: String) {
    guard !input.utf8.contains(0) else { return nil }
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let capacity = socklen_t(buffer.count)
    if inet_pton(AF_INET, input, &ipv4) == 1 {
      guard inet_ntop(AF_INET, &ipv4, &buffer, capacity) != nil else { return nil }
      let value = UInt32(bigEndian: ipv4.s_addr)
      family = .ipv4
      if value & 0xffc0_0000 == 0x6440_0000 {
        network = .tailscale
      } else if value & 0xff00_0000 == 0x0a00_0000
        || value & 0xfff0_0000 == 0xac10_0000 || value & 0xffff_0000 == 0xc0a8_0000
      {
        network = .lan
      } else {
        network = nil
      }
    } else if inet_pton(AF_INET6, input, &ipv6) == 1 {
      guard inet_ntop(AF_INET6, &ipv6, &buffer, capacity) != nil else { return nil }
      family = .ipv6
      network = withUnsafeBytes(of: ipv6) { bytes in
        if bytes.prefix(6).elementsEqual([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]) {
          return .tailscale
        }
        return bytes[0] & 0xfe == 0xfc ? .lan : nil
      }
    } else {
      return nil
    }
    text = String(
      decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
  }
}
