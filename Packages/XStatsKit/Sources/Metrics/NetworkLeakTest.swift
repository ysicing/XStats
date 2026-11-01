// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Network
import dnssd

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
    return try await dns(
      request: { request in
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
      },
      register: { url, ipv6 in
        // 与脚本的 curl -4/-6 一致；缺少某个地址族不应阻止 DNS 检测。
        _ = await AddressFamilyRequest.get(url, ipv6: ipv6, timeout: 5)
        try Task.checkCancellation()
      },
      resolve: { host in
        await DNSLeakQuery(host: host).run()
        try Task.checkCancellation()
      })
  }

  // 传输可替换，回归不访问真实服务，也不污染开发机 DNS。
  static func dns(
    request: @Sendable (URLRequest) async throws -> Data,
    register: @Sendable (URL, Bool) async throws -> Void,
    resolve: @escaping @Sendable (String) async throws -> Void
  ) async throws -> DNSResult {
    try Task.checkCancellation()
    struct Run: Decodable {
      let kind: String
      let run_id: String
      let cmd: String
      let url: String
    }
    let sessionData = try await request(dnsCommand("start", path: "/dnsleak"))
    guard sessionData.count <= 65_536,
      let run = try? JSONDecoder().decode(Run.self, from: sessionData)
    else { throw Failure.invalidResponse }
    let token = run.run_id
    guard (1...63).contains(token.utf8.count),
      token.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
      }),
      run.kind == "test", run.cmd == "dnsleaktest", run.url == "/dnsleak/test/\(token)"
    else { throw Failure.invalidResponse }
    // 使用当前网页的 start / exec / checkrun 协议；不采纳服务端的泄漏结论。
    for ipv6 in [false, true] {
      try Task.checkCancellation()
      do {
        let host = ipv6 ? "ipv6.bash.ws" : "ipv4.bash.ws"
        try await register(URL(string: "https://\(host)/myip/test/\(token)")!, ipv6)
      } catch {
        try Task.checkCancellation()
      }
    }
    try Task.checkCancellation()
    struct Execution: Decodable { let started: Int }
    let execution = try await request(dnsCommand("exec", path: run.url))
    guard execution.count <= 65_536,
      let status = try? JSONDecoder().decode(Execution.self, from: execution), status.started == 1
    else { throw Failure.invalidResponse }
    // 30 个不同域名采样递归出口池，最多两个查询同时进行；只解析，不发送 ICMP 或 HTTPS。
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 1...30 {
        try Task.checkCancellation()
        if index > 2 { try await group.next() }
        group.addTask {
          try Task.checkCancellation()
          do {
            try await resolve("\(index).\(token).bash.ws")
          } catch {
            // NXDOMAIN 等失败仍可能已触发权威查询，最终以服务端观察为准。
            try Task.checkCancellation()
          }
          try Task.checkCancellation()
        }
      }
      try await group.waitForAll()
    }
    try Task.checkCancellation()
    struct Progress: Decodable { let done: Int }
    var completed = false
    // 权威查询记录可能稍晚入库；只在当前检测期间有界等待，取消后不继续轮询。
    for attempt in 0..<4 {
      if attempt > 0 { try await Task.sleep(for: .milliseconds(1500)) }
      try Task.checkCancellation()
      let data = try await request(dnsCommand("checkrun", path: run.url))
      guard data.count <= 65_536,
        let progress = try? JSONDecoder().decode(Progress.self, from: data),
        progress.done == 0 || progress.done == 1
      else { throw Failure.invalidResponse }
      if progress.done == 1 {
        completed = true
        break
      }
    }
    guard completed else { throw Failure.unavailable }
    try Task.checkCancellation()
    let resultRequest = URLRequest(
      url: URL(string: "https://bash.ws/dnsleak/test/\(token)?json=2")!, timeoutInterval: 6)
    let data = try await request(resultRequest)
    try Task.checkCancellation()
    return try decodeDNS(data)
  }

  private static func dnsCommand(_ action: String, path: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://bash.ws/dnsleak")!, timeoutInterval: 6)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    // path 仅由固定路径和已校验的字母数字 run_id 构成，不接受服务端任意 URL。
    request.httpBody = Data("ajax=1&\(action)=1&url=\(path)".utf8)
    if action == "checkrun" {
      // 仅查询完成状态，避免服务端附带完整 HTML 超过有界响应上限。
      request.httpBody?.append(Data("&summary=1".utf8))
    }
    return request
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

/// 复现脚本 ping 前的系统解析，避免 HTTPS 代理代替本机解析探测域名。
/// 每个实例仅运行一次；DNS 回调、超时和取消都在同一串行队列上释放查询并恢复一次。
final class DNSLeakQuery: @unchecked Sendable {
  private static let queue = DispatchQueue(label: "XStats.DNSLeakQuery")
  private let host: String
  private let timeout: TimeInterval
  private var service: DNSServiceRef?
  private var continuation: CheckedContinuation<Void, Never>?
  private var finished = false
  private var deadline: DispatchWorkItem?

  init(host: String, timeout: TimeInterval = 2) {
    self.host = host.hasSuffix(".") ? host : host + "."
    self.timeout = timeout
  }

  func run() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let cancelled = Task.isCancelled
        Self.queue.async { [self] in
          guard !cancelled, !finished else {
            continuation.resume()
            return
          }
          self.continuation = continuation
          let status = DNSServiceGetAddrInfo(
            &service, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host,
            { _, _, _, _, _, _, _, context in
              guard let context else { return }
              Unmanaged<DNSLeakQuery>.fromOpaque(context).takeUnretainedValue().finish()
            }, Unmanaged.passUnretained(self).toOpaque())
          guard status == kDNSServiceErr_NoError, let service,
            DNSServiceSetDispatchQueue(service, Self.queue) == kDNSServiceErr_NoError
          else {
            finish()
            return
          }
          let deadline = DispatchWorkItem { [weak self] in self?.finish() }
          self.deadline = deadline
          Self.queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        }
      }
    } onCancel: {
      Self.queue.async { self.finish() }
    }
    // C 回调只持有非拥有指针，确保完成和释放查询之前实例始终存活。
    withExtendedLifetime(self) {}
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    deadline?.cancel()
    deadline = nil
    if let service {
      DNSServiceRefDeallocate(service)
      self.service = nil
    }
    let continuation = continuation
    self.continuation = nil
    continuation?.resume()
  }
}
