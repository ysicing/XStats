import Foundation

/// 一个探针的测量结果
public struct GlobalpingProbe: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var continent: String
    public var countryCode: String
    public var city: String
    /// 探针所在网络（运营商或机房）
    public var network: String
    /// 往返延迟的平均值，测不到时为 nil
    public var milliseconds: Double?
    /// 丢包百分比
    public var loss: Double?
}

/// 一次全球探针测量
public struct GlobalpingRun: Sendable, Equatable, Codable {
    public var id: String
    public var target: String
    public var date: Date
    public var probes: [GlobalpingProbe]
    /// 本小时内还剩多少次额度（按调用方 IP 计）
    public var remaining: Int?
    public var limit: Int?
}

/// Globalping 的公开接口：全球社区探针 ping 指定目标。
///
/// 这里**不带任何密钥**，匿名调用。额度按调用方 IP 计算（每小时 250 次，一个探针算一次），
/// 每台 Mac 用自己的额度，不经过我们的服务器，也不消耗我们的额度。
///
/// 注意：Globalping 的测量参数与结果是公开的，凭测量 ID 谁都能查到，
/// 所以只测用户自己填写的域名，不要把用户的公网 IP 发过去。
public enum GlobalpingClient {
    public enum Failure: Error, Sendable, Equatable {
        /// 超出额度，附带需要等待的秒数
        case rateLimited(seconds: Int?)
        case http(Int)
        case invalidTarget
        case timeout
    }

    static let base = URL(string: "https://api.globalping.io/v1/measurements")!
    /// 结果通常几秒内就绪，轮询间隔 0.5 秒也在官方限制（每个测量每秒 2 次）之内
    static let pollInterval: Duration = .milliseconds(500)
    static let pollTimeout: Duration = .seconds(30)

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["User-Agent": "XStats"]
        return URLSession(configuration: configuration)
    }()

    /// 从全球按大洲分散挑 `probes` 个探针 ping 目标
    public static func ping(target: String, probes: Int) async throws -> GlobalpingRun {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.contains(" "), target.contains(".") else { throw Failure.invalidTarget }

        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 各大洲自带数量时不能再传总数，否则接口返回 400
        request.httpBody = try JSONEncoder().encode(Request(target: target, locations: distribution(probes)))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.http(0) }
        let limits = rateLimits(http)
        if http.statusCode == 429 {
            throw Failure.rateLimited(seconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
        guard http.statusCode == 202 || http.statusCode == 200,
              let created = try? JSONDecoder().decode(Created.self, from: data) else {
            throw Failure.http(http.statusCode)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: pollTimeout)
        while clock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            try Task.checkCancellation()
            guard let (data, response) = try? await session.data(from: base.appendingPathComponent(created.id)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let measurement = try? JSONDecoder().decode(Measurement.self, from: data) else { continue }
            guard measurement.status != "in-progress" else { continue }
            return GlobalpingRun(id: created.id, target: target, date: Date(),
                                 probes: measurement.results.enumerated().map { index, item in
                                     GlobalpingProbe(id: "\(created.id)-\(index)",
                                                     continent: item.probe.continent,
                                                     countryCode: item.probe.country,
                                                     city: item.probe.city,
                                                     network: item.probe.network,
                                                     milliseconds: item.result.stats?.avg,
                                                     loss: item.result.stats?.loss)
                                 },
                                 remaining: limits.remaining, limit: limits.limit)
        }
        throw Failure.timeout
    }

    static func rateLimits(_ response: HTTPURLResponse) -> (limit: Int?, remaining: Int?) {
        (response.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init),
         response.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init))
    }

    /// 按大洲分配探针数，结果覆盖面更均匀；余数补给亚洲、欧洲、北美
    static func distribution(_ probes: Int) -> [Location] {
        let weights: [(String, Double)] = [("AS", 0.3), ("EU", 0.25), ("NA", 0.25), ("SA", 0.08), ("OC", 0.06), ("AF", 0.06)]
        var counts = weights.map { (continent: $0.0, limit: Int((Double(probes) * $0.1).rounded(.down))) }
        var index = 0
        while counts.reduce(0, { $0 + $1.limit }) < probes {
            counts[index % 3].limit += 1
            index += 1
        }
        return counts.filter { $0.limit > 0 }.map { Location(continent: $0.continent, limit: $0.limit) }
    }

    // MARK: 报文

    struct Location: Codable, Sendable {
        var continent: String
        var limit: Int
    }

    private struct Request: Codable {
        var type = "ping"
        var target: String
        var locations: [Location]
        var measurementOptions = Options()

        struct Options: Codable {
            var packets = 4
        }
    }

    private struct Created: Codable {
        var id: String
    }

    private struct Measurement: Codable {
        var status: String
        var results: [Item]

        struct Item: Codable {
            var probe: Probe
            var result: Result
        }

        struct Probe: Codable {
            var continent: String
            var country: String
            var city: String
            var network: String
        }

        struct Result: Codable {
            var status: String?
            var stats: Stats?
        }

        struct Stats: Codable {
            var min: Double?
            var avg: Double?
            var max: Double?
            var loss: Double?
        }
    }
}
