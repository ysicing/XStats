// OpenStats source retained under MIT; XStats adaptations Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Network

// MARK: - 延迟

/// 一组 TCP 建连计时的结果
public struct LatencyResult: Sendable, Codable, Equatable {
    /// 最快一次的毫秒数；全部失败时为 nil
    public var best: Double?
    public var attempts: Int
    public var failures: Int

    public var isReachable: Bool { best != nil }

    public init(best: Double? = nil, attempts: Int = 0, failures: Int = 0) {
        self.best = best
        self.attempts = attempts
        self.failures = failures
    }
}

/// 用 TCP 建连的耗时代替 ping：目标节点大多不回 ICMP，握手时间同样能反映往返延迟。
/// 只建连、不发数据，连上立即断开。
///
/// 只在不经代理时准确：经 Surge、Clash 等代理时握手由本机代理当场应答，要改用 `HTTPLatencyProbe`
public enum TCPLatencyProbe {
    public static func measure(host: String, port: UInt16, path: SpeedPath = .system, attempts: Int = 3,
                               timeout: TimeInterval = 3) async -> LatencyResult {
        var result = LatencyResult(attempts: attempts)
        // 需要自己解析的先解析好，DNS 查询不计入握手时间
        guard let address = await path.address(for: host) else {
            result.failures = attempts
            return result
        }
        for _ in 0..<attempts {
            if Task.isCancelled { break }
            if let milliseconds = await connect(host: address, port: port, path: path, timeout: timeout) {
                result.best = min(result.best ?? .greatestFiniteMagnitude, milliseconds)
            } else {
                result.failures += 1
            }
        }
        return result
    }

    private static let queue = DispatchQueue(label: "work.12306.xstats.speedtest.tcp", qos: .utility)

    private static func connect(host: String, port: UInt16, path: SpeedPath, timeout: TimeInterval) async -> Double? {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = Int(timeout.rounded(.up))
        options.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: options)
        path.apply(to: parameters)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let clock = ContinuousClock()
        let start = clock.now
        let gate = ContinuationGate<Double?>()
        let milliseconds: Double? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.attach(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resume(SpeedConnection.milliseconds(clock.now - start))
                    case .failed, .cancelled:
                        gate.resume(nil)
                    case .waiting:
                        // 路由不可达、端口被拒：不再等超时，直接算这次失败
                        gate.resume(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                // connectionTimeout 在个别情况下不触发状态变化，兜一个自己的超时
                queue.asyncAfter(deadline: .now() + timeout) { gate.resume(nil) }
            }
        } onCancel: {
            gate.resume(nil)
        }
        connection.cancel()
        return milliseconds
    }
}

/// 经代理时的延迟：同一条连接上先发一次请求预热（代理这时才真正去连目标），再接连计时几次取最快。
/// 每次都要等目标的响应回来，测到的是经代理到目标的真实往返，包括代理服务器那一段
public enum HTTPLatencyProbe {
    public static func measure(_ url: URL, path: SpeedPath, method: String = "HEAD", samples: Int = 3,
                               timeout: TimeInterval = 5) async -> LatencyResult {
        var result = LatencyResult(attempts: samples, failures: samples)
        let slot = ConnectionSlot()
        // 建连与全部请求共用一个期限，目标一直不回就掐断
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout * 3))
            slot.cancel()
        }
        defer { watchdog.cancel() }
        let times: [Double] = await withTaskCancellationHandler {
            var times: [Double] = []
            // 服务器偶尔回个错误就关掉连接，换一条连接重新预热，把样本补齐
            for _ in 0..<2 where times.count < samples && !slot.isCancelled {
                guard let connection = await SpeedConnection.open(url, path: path, timeout: timeout) else { continue }
                slot.hold(connection)
                times += await connection.roundTrips(samples - times.count + 1, method: method).dropFirst().map(\.milliseconds)
                connection.cancel()
            }
            return times
        } onCancel: {
            slot.cancel()
        }
        result.best = times.min()
        result.failures = samples - times.count
        return result
    }
}

// MARK: - 吞吐

/// 一次测速的用量上限：时间与流量哪个先到就停在哪
public struct SpeedLimit: Sendable, Equatable, Codable {
    public var seconds: Double
    public var bytes: Int

    public init(seconds: Double, megabytes: Int) {
        self.seconds = seconds
        bytes = megabytes * 1024 * 1024
    }
}

/// 单个节点一次测速最多花多少时间与流量，设置里可选
public enum SpeedTestBudget: String, Sendable, CaseIterable, Codable {
    case light, medium, full

    public var limit: SpeedLimit {
        switch self {
        case .light: SpeedLimit(seconds: 3, megabytes: 20)
        case .medium: SpeedLimit(seconds: 5, megabytes: 50)
        case .full: SpeedLimit(seconds: 10, megabytes: 200)
        }
    }
}

public struct SpeedResult: Sendable, Equatable, Codable {
    public var bitsPerSecond: Double
    /// 实际用掉的流量
    public var bytes: Int
    public var seconds: Double
}

/// 下载与上传测速：边传边算，达到上限就掐断连接，不会把整份文件收完。
/// 连接建在 Network.framework 上，直连时绑定物理网卡绕开代理，经代理时按系统设置走
public enum ThroughputProbe {
    /// 开头的慢启动不计入速度
    static let warmup: Double = 0.5
    /// 建连（含 TLS 握手）最多等多久；经代理时要多走一段，给宽一点
    static let connectTimeout: TimeInterval = 8

    public static func download(_ url: URL, limit: SpeedLimit, path: SpeedPath = .system,
                                progress: @escaping @Sendable (Double, Int) -> Void = { _, _ in }) async -> SpeedResult? {
        await receive(url, limit: limit, path: path, range: true, repeats: false, progress: progress).result
    }

    /// 反复请求同一个地址直到用满上限，并读出响应头（Cloudflare 单次最多给 25 MB，
    /// 而且边缘节点信息就在响应头里）
    static func downloadRepeatedly(_ url: URL, limit: SpeedLimit, path: SpeedPath,
                                   progress: @escaping @Sendable (Double, Int) -> Void = { _, _ in })
        async -> (result: SpeedResult?, headers: [String: String]) {
        await receive(url, limit: limit, path: path, range: false, repeats: true, progress: progress)
    }

    public static func upload(_ url: URL, bytes: Int, limit: SpeedLimit, path: SpeedPath = .system,
                              progress: @escaping @Sendable (Double, Int) -> Void = { _, _ in }) async -> SpeedResult? {
        await guarded(limit: limit) { slot in
            guard let connection = await SpeedConnection.open(url, path: path, timeout: connectTimeout) else { return nil }
            slot.hold(connection)
            defer { connection.cancel() }
            var meter = SpeedMeter(limit: limit)
            guard await connection.sendRequest("POST", headers: [("Content-Type", "application/octet-stream"),
                                                                 ("Content-Length", String(bytes))]) else { return nil }
            let complete = await connection.sendBody(bytes: bytes) { count in
                meter.add(count)
                progress(meter.rate, meter.bytes)
                return !meter.reachedLimit
            }
            // 整段交给协议栈时还有一部分在发送缓冲区里，等服务器回了响应（收齐了）再停表
            if complete { _ = await connection.readResponse() }
            return meter.result()
        } ?? nil
    }

    private static func receive(_ url: URL, limit: SpeedLimit, path: SpeedPath, range: Bool, repeats: Bool,
                                progress: @escaping @Sendable (Double, Int) -> Void)
        async -> (result: SpeedResult?, headers: [String: String]) {
        let headers = range ? [("Range", "bytes=0-\(limit.bytes - 1)")] : []
        return await guarded(limit: limit) { slot in
            var meter = SpeedMeter(limit: limit)
            var connection: SpeedConnection?
            var responseHeaders: [String: String] = [:]
            defer { connection?.cancel() }
            while !slot.isCancelled {
                if connection == nil {
                    connection = await SpeedConnection.open(url, path: path, timeout: connectTimeout)
                    guard let connection else { break }
                    slot.hold(connection)
                }
                guard let current = connection, await current.sendRequest("GET", headers: headers),
                      let response = await current.readResponse(), (200..<300).contains(response.status) else { break }
                responseHeaders = response.headers
                let complete = await current.readBody(response) { count in
                    meter.add(count)
                    progress(meter.rate, meter.bytes)
                    return !meter.reachedLimit
                }
                // 还没到上限、这次响应又正常收完：接着请求，把测量凑满
                guard repeats, complete, !meter.reachedLimit, meter.bytes > 0 else { break }
                if !response.isReusable {
                    current.cancel()
                    connection = nil
                }
            }
            return (meter.result(), responseHeaders)
        } ?? (nil, [:])
    }

    /// 取消时掐断正在用的连接；数据卡住不动时看门狗到点也掐断。被取消的测量不给结果
    private static func guarded<T: Sendable>(limit: SpeedLimit, _ body: (ConnectionSlot) async -> T) async -> T? {
        let slot = ConnectionSlot()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(limit.seconds + connectTimeout))
            slot.cancel()
        }
        defer { watchdog.cancel() }
        let value = await withTaskCancellationHandler {
            await body(slot)
        } onCancel: {
            slot.cancel()
        }
        return Task.isCancelled ? nil : value
    }
}

/// 统计传输速度：从第一笔数据开始计时，热身之后的部分才算速度；时间或流量到上限就该停
struct SpeedMeter {
    let limit: SpeedLimit
    private let clock = ContinuousClock()
    private var start: ContinuousClock.Instant?
    /// 热身结束时的时间与字节数，速度从这里开始算
    private var mark: (time: ContinuousClock.Instant, bytes: Int)?
    private(set) var bytes = 0
    private(set) var reachedLimit = false

    init(limit: SpeedLimit) {
        self.limit = limit
    }

    mutating func add(_ count: Int) {
        let now = clock.now
        if start == nil { start = now }
        bytes += count
        let seconds = Self.seconds(start.map { now - $0 } ?? .zero)
        if mark == nil, seconds >= ThroughputProbe.warmup { mark = (now, bytes) }
        reachedLimit = bytes >= limit.bytes || seconds >= limit.seconds
    }

    /// 热身之后的平均速度；还没过热身期就用全程平均，让界面上的数字先动起来
    var rate: Double {
        guard let start else { return 0 }
        let seconds = Self.seconds(clock.now - (mark?.time ?? start))
        guard seconds > 0.05 else { return 0 }
        return Double(bytes - (mark?.bytes ?? 0)) * 8 / seconds
    }

    /// 截至此刻的结果；没收到数据或时间太短返回 nil
    func result() -> SpeedResult? {
        guard let start, bytes > 0 else { return nil }
        let now = clock.now
        let seconds = Self.seconds(now - (mark?.time ?? start))
        let measured = bytes - (mark?.bytes ?? 0)
        guard seconds > 0.05, measured > 0 else { return nil }
        return SpeedResult(bitsPerSecond: Double(measured) * 8 / seconds, bytes: bytes, seconds: Self.seconds(now - start))
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

// MARK: - 本机宽带（Cloudflare）

/// 本机宽带测速的结果：下行、上行、空载延迟与抖动，以及这次走的 Cloudflare 边缘节点
public struct BroadbandResult: Sendable, Equatable, Codable {
    public var download: SpeedResult?
    public var upload: SpeedResult?
    public var latencyMilliseconds: Double?
    public var jitterMilliseconds: Double?
    public var colo: String?
    public var city: String?
    public var totalBytes: Int = 0
}

/// 用 speed.cloudflare.com 测本机宽带：先测延迟与抖动，再测下行、上行。
/// 这是官方测速站自己用的接口，不需要密钥
public enum BroadbandTest {
    public enum Stage: String, Sendable { case latency, download, upload }

    static let downURL = URL(string: "https://speed.cloudflare.com/__down?bytes=")!
    static let upURL = URL(string: "https://speed.cloudflare.com/__up")!
    /// 上行的数据要在内存里生成，单独设一个上限
    static let uploadMegabytes = 25
    /// 下行单次请求的大小：再大 Cloudflare 会直接拒绝，凑上限靠多请求几次
    static let chunkMegabytes = 25
    static let latencySamples = 10

    public static func run(limit: SpeedLimit, path: SpeedPath = .system,
                           stage: @escaping @Sendable (Stage) -> Void = { _ in },
                           progress: @escaping @Sendable (Double, Int) -> Void = { _, _ in }) async -> BroadbandResult {
        var result = BroadbandResult()

        stage(.latency)
        let (samples, headers) = await latency(path: path)
        result.colo = headers["cf-meta-colo"] ?? headers["colo"]
        result.city = headers["cf-meta-city"]
        if !samples.isEmpty {
            result.latencyMilliseconds = samples.min()
            // 抖动看相邻两次的差；偶尔一次重新建连会拉出一个大值，去掉最大的那个差
            let gaps = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.sorted().dropLast()
            if !gaps.isEmpty {
                result.jitterMilliseconds = gaps.reduce(0, +) / Double(gaps.count)
            }
        }
        guard !Task.isCancelled else { return result }

        stage(.download)
        let url = URL(string: downURL.absoluteString + String(chunkMegabytes * 1024 * 1024))!
        let (download, downloadHeaders) = await ThroughputProbe.downloadRepeatedly(url, limit: limit, path: path,
                                                                                          progress: progress)
        result.download = download
        result.totalBytes += download?.bytes ?? 0
        result.colo = result.colo ?? downloadHeaders["cf-meta-colo"] ?? downloadHeaders["colo"]
        guard !Task.isCancelled else { return result }

        stage(.upload)
        let uploadBytes = min(limit.bytes, uploadMegabytes * 1024 * 1024)
        let upload = await ThroughputProbe.upload(upURL, bytes: uploadBytes, limit: limit, path: path,
                                                 progress: progress)
        result.upload = upload
        result.totalBytes += upload?.bytes ?? 0
        return result
    }

    /// 同一条连接上连续请求空响应，用往返时间当延迟。经代理时也准：每次都要等 Cloudflare 真的回话
    private static func latency(path: SpeedPath) async -> ([Double], [String: String]) {
        let url = URL(string: downURL.absoluteString + "0")!
        let slot = ConnectionSlot()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(ThroughputProbe.connectTimeout + 5))
            slot.cancel()
        }
        defer { watchdog.cancel() }
        return await withTaskCancellationHandler {
            guard let connection = await SpeedConnection.open(url, path: path, timeout: ThroughputProbe.connectTimeout) else {
                return ([], [:])
            }
            slot.hold(connection)
            defer { connection.cancel() }
            let trips = await connection.roundTrips(latencySamples, method: "GET")
            // 前两次还在预热（经代理时代理这时才去连 Cloudflare），不算延迟；
            // 和 Cloudflare 自己的测速一样，扣掉响应头里报的服务器处理时间
            let samples = trips.dropFirst(2).map { max(0, $0.milliseconds - serverMilliseconds($0.response.headers)) }
            return (samples, trips.first?.response.headers ?? [:])
        } onCancel: {
            slot.cancel()
        }
    }

    /// Server-Timing 里各段服务器处理耗时之和，例如 `cfSpeedEdge;dur=3, cfSpeedWorker;dur=21` 得 24
    static func serverMilliseconds(_ headers: [String: String]) -> Double {
        (headers["server-timing"] ?? "").split(separator: ",").reduce(0) { total, entry in
            let duration = entry.split(separator: ";").lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("dur=") }
                .flatMap { Double($0.dropFirst(4)) }
            return total + (duration ?? 0)
        }
    }
}
