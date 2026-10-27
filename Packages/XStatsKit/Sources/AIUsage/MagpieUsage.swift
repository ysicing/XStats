// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 采用 Magpie 的原始周期和 Token 口径，不把跨账户额度相加，也不混入本机日志。
public enum MagpiePeriod: String, CaseIterable, Sendable, Codable {
  case daily = "today"
  case weekly = "7d"
  case monthly = "30d"
  case cumulative = "all"
}

public struct MagpieQuota: Decodable, Equatable, Sendable, Identifiable {
  public let provider: String
  public let name: String
  public let kind: String
  public let plan: String?
  public let user: String?
  public let until: Date?
  public let resets: MagpieResetCredits?
  public let windows: [MagpieQuotaWindow]
  public let balance: String?
  public let error: String?
  public let readAt: Date?
  public let last: Bool?
  public let from: String?
  public let alias: String?
  var ordinal = 0
  // 同名账户有身份信息时按身份区分，刷新顺序变化不能把展开状态移交给另一个账户。
  public var id: String { "\(provider):\(name):\(kind):\(user ?? ""):\(ordinal)" }
  private enum CodingKeys: String, CodingKey {
    case provider, name, kind, plan, user, until, resets, windows, balance, error, readAt, last
    case from, alias
  }
}

extension MagpieQuota {
  /// 账号、有效期和重置卡只用于展示：格式不符或超出上限时按未知处理，不能让整份额度列表读取失败。
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    provider = try c.decode(String.self, forKey: .provider)
    name = try c.decode(String.self, forKey: .name)
    kind = try c.decode(String.self, forKey: .kind)
    plan = try c.decodeIfPresent(String.self, forKey: .plan)
    let user = (try? c.decodeIfPresent(String.self, forKey: .user)) ?? nil
    self.user = user.flatMap { $0.count <= 512 ? $0 : nil }
    until = (try? c.decodeIfPresent(Date.self, forKey: .until)) ?? nil
    let resets = (try? c.decodeIfPresent(MagpieResetCredits.self, forKey: .resets)) ?? nil
    self.resets = resets.flatMap { $0.isWithinBounds ? $0 : nil }
    windows = try c.decode([MagpieQuotaWindow].self, forKey: .windows)
    balance = try c.decodeIfPresent(String.self, forKey: .balance)
    error = try c.decodeIfPresent(String.self, forKey: .error)
    readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
    last = try c.decodeIfPresent(Bool.self, forKey: .last)
    from = (try? c.decodeIfPresent(String.self, forKey: .from)).flatMap {
      $0.count <= 512 ? $0 : nil
    }
    alias = (try? c.decodeIfPresent(String.self, forKey: .alias)).flatMap {
      $0.count <= 512 ? $0 : nil
    }
  }
}

/// Magpie 返回的剩余重置卡；缺少数量表示未知，不能当作零张。
public struct MagpieResetCredits: Decodable, Equatable, Sendable {
  public let count: Int?
  public let until: Date?
  public let each: [Credit]?

  public struct Credit: Decodable, Equatable, Sendable {
    public let until: Date?
  }

  var isWithinBounds: Bool {
    (count.map { (0...1_000_000).contains($0) } ?? true) && (each?.count ?? 0) <= 1000
  }
}

public struct MagpieQuotaWindow: Decodable, Equatable, Sendable {
  public let name: String
  public let used: Double?
  public let remaining: Double?
  public let resetsAt: Date?
  public let unlimited: Bool?
  public let display: String?
}

public struct MagpieUsageSummary: Decodable, Equatable, Sendable {
  public let period: MagpiePeriod
  public let bucket: String
  public let input: Int
  public let output: Int
  public let cacheRead: Int
  public let cacheWrite: Int
  public let calls: Int
  public let cost: Double
  public let unpriced: Int
  public let models: [MagpieUsageModel]
  public let series: [MagpieUsageBucket]
  public var total: Int { input + output }

  enum CodingKeys: String, CodingKey {
    case period, bucket, input, output, calls, cost, unpriced, models, series
    case cacheRead = "cache_read"
    case cacheWrite = "cache_write"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    period = try c.decode(MagpiePeriod.self, forKey: .period)
    bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? "day"
    input = try c.decode(Int.self, forKey: .input)
    output = try c.decode(Int.self, forKey: .output)
    cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
    cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
    calls = try c.decode(Int.self, forKey: .calls)
    cost = try c.decode(Double.self, forKey: .cost)
    unpriced = try c.decodeIfPresent(Int.self, forKey: .unpriced) ?? 0
    models = try c.decodeIfPresent([MagpieUsageModel].self, forKey: .models) ?? []
    series = try c.decodeIfPresent([MagpieUsageBucket].self, forKey: .series) ?? []
  }

}

public struct MagpieUsageModel: Decodable, Equatable, Sendable, Identifiable {
  public let id: String
  public let provider: String
  public let model: String
  public let input: Int
  public let output: Int
  public var total: Int { input + output }
}

public struct MagpieUsageBucket: Decodable, Equatable, Sendable {
  public let time: Date
  public let input: Int
  public let output: Int
  public let calls: Int?
  public let cost: Double?
  public let decodeMilliseconds: Double?
  public let decodeOutput: Int?
  public let decodeCount: Int?

  enum CodingKeys: String, CodingKey {
    case time, input, output, calls, cost
    case decodeMilliseconds = "decode_ms"
    case decodeOutput = "decode_out"
    case decodeCount = "decode_n"
  }

  /// 使用有测速记录的输出量与生成耗时，不能将首字等待或未测速请求混入分母。
  public var tokensPerSecond: Double? {
    guard let decodeMilliseconds, decodeMilliseconds > 0,
      let decodeOutput, let decodeCount, decodeCount > 0
    else { return nil }
    return Double(decodeOutput) / decodeMilliseconds * 1000
  }
}

public enum MagpieFailure: Error, Sendable, Equatable {
  case unavailable, invalidResponse, responseTooLarge
}

public protocol MagpieFetching: Sendable {
  func quotas() async throws -> [MagpieQuota]
  func usage(period: MagpiePeriod) async throws -> MagpieUsageSummary
}

public struct MagpieClient: MagpieFetching, Sendable {
  public let baseURL: URL
  private let session: URLSession
  static let responseLimit = 8 * 1024 * 1024

  public init(baseURL: URL = URL(string: "http://127.0.0.1:3425")!) throws {
    guard baseURL.scheme == "http",
      ["127.0.0.1", "localhost", "[::1]", "::1"].contains(baseURL.host),
      baseURL.user == nil, baseURL.password == nil, baseURL.query == nil,
      baseURL.fragment == nil, baseURL.path.isEmpty || baseURL.path == "/",
      let port = baseURL.port, (1024...65535).contains(port)
    else { throw MagpieFailure.invalidResponse }
    self.baseURL = baseURL
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    session = URLSession(
      configuration: configuration, delegate: MagpieRedirectGuard(), delegateQueue: nil)
  }

  public func quotas() async throws -> [MagpieQuota] {
    let data = try await read(path: "v1/magpie/quotas")
    try Task.checkCancellation()
    return try Self.decodeQuotas(data)
  }

  public func usage(period: MagpiePeriod) async throws -> MagpieUsageSummary {
    let data = try await read(path: "v1/magpie/usage", period: period)
    try Task.checkCancellation()
    return try Self.decodeUsage(data, period: period)
  }

  private func read(path: String, period: MagpiePeriod? = nil) async throws -> Data {
    var components = URLComponents(
      url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if let period { components.queryItems = [URLQueryItem(name: "period", value: period.rawValue)] }
    var request = URLRequest(url: components.url!)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else { throw MagpieFailure.unavailable }
      if http.statusCode == 404 { throw MagpieFailure.invalidResponse }
      guard http.statusCode == 200 else { throw MagpieFailure.unavailable }
      guard response.expectedContentLength <= Self.responseLimit else {
        throw MagpieFailure.responseTooLarge
      }
      var data = Data()
      for try await byte in bytes {
        if data.count >= Self.responseLimit { throw MagpieFailure.responseTooLarge }
        if data.count % 16_384 == 0 { try Task.checkCancellation() }
        data.append(byte)
      }
      return data
    } catch let failure as MagpieFailure { throw failure } catch is CancellationError {
      throw CancellationError()
    } catch { throw MagpieFailure.unavailable }
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let string = try decoder.singleValueContainer().decode(String.self)
      let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
      let whole = Date.ISO8601FormatStyle()
      guard let date = (try? fractional.parse(string)) ?? (try? whole.parse(string)) else {
        throw MagpieFailure.invalidResponse
      }
      return date
    }
    return decoder
  }

  static func decodeQuotas(_ data: Data) throws -> [MagpieQuota] {
    struct Envelope: Decodable {
      let object: String
      let data: [MagpieQuota]
    }
    guard data.count <= responseLimit else { throw MagpieFailure.responseTooLarge }
    guard let envelope = try? decoder().decode(Envelope.self, from: data) else {
      throw MagpieFailure.invalidResponse
    }
    guard envelope.object == "list", envelope.data.count <= 1000 else {
      throw MagpieFailure.invalidResponse
    }
    var occurrences: [String: Int] = [:]
    return try envelope.data.map { item in
      guard item.windows.count <= 100, item.provider.count <= 256, item.name.count <= 256 else {
        throw MagpieFailure.invalidResponse
      }
      guard (item.plan?.count ?? 0) <= 512, (item.balance?.count ?? 0) <= 2048,
        (item.error?.count ?? 0) <= 4096
      else { throw MagpieFailure.invalidResponse }
      for window in item.windows {
        guard window.name.count <= 256, (window.display?.count ?? 0) <= 2048 else {
          throw MagpieFailure.invalidResponse
        }
        // 服务端可能报告超过 100% 的已用额度，但剩余额度仍应在 0–100% 之间。
        if let used = window.used {
          guard used.isFinite, (0...1_000_000_000).contains(used) else {
            throw MagpieFailure.invalidResponse
          }
        }
        if let remaining = window.remaining {
          guard remaining.isFinite, (0...100).contains(remaining) else {
            throw MagpieFailure.invalidResponse
          }
        }
      }
      var quota = item
      let identity = quota.id
      quota.ordinal = occurrences[identity, default: 0]
      occurrences[identity, default: 0] += 1
      return quota
    }
  }

  static func decodeUsage(_ data: Data, period: MagpiePeriod) throws -> MagpieUsageSummary {
    guard data.count <= responseLimit else { throw MagpieFailure.responseTooLarge }
    guard let summary = try? decoder().decode(MagpieUsageSummary.self, from: data) else {
      throw MagpieFailure.invalidResponse
    }
    // 总量、图表和排行都要能安全相加；不接受负值、非有限费用或无限增长的列表。
    let counts =
      [
        summary.input, summary.output, summary.cacheRead, summary.cacheWrite, summary.calls,
        summary.unpriced,
      ]
      + summary.series.flatMap {
        [$0.input, $0.output] + [$0.calls, $0.decodeOutput, $0.decodeCount].compactMap { $0 }
      }
      + summary.models.flatMap { [$0.input, $0.output] }
    guard summary.period == period, summary.cost.isFinite, summary.cost >= 0,
      summary.models.count <= 2000, summary.series.count <= 10_000,
      ["hour", "day", "week"].contains(summary.bucket),
      Set(summary.series.map(\.time)).count == summary.series.count,
      Set(summary.models.map(\.id)).count == summary.models.count,
      counts.allSatisfy({ (0...100_000_000_000_000).contains($0) }),
      summary.series.allSatisfy({
        [$0.cost, $0.decodeMilliseconds].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
          && ($0.tokensPerSecond?.isFinite ?? true)
      }),
      summary.models.allSatisfy({
        $0.id.count <= 512 && $0.model.count <= 1024 && $0.provider.count <= 256
      })
    else { throw MagpieFailure.invalidResponse }
    return summary
  }
}

private final class MagpieRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? { nil }
}
