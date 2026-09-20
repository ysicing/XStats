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
/// 只建连、不发数据，连上立即断开
public enum TCPLatencyProbe {
    public static func measure(host: String, port: UInt16, attempts: Int = 3,
                               timeout: TimeInterval = 3) async -> LatencyResult {
        var result = LatencyResult(attempts: attempts)
        for _ in 0..<attempts {
            if Task.isCancelled { break }
            if let milliseconds = await connect(host: host, port: port, timeout: timeout) {
                result.best = min(result.best ?? .greatestFiniteMagnitude, milliseconds)
            } else {
                result.failures += 1
            }
        }
        return result
    }

    private static let queue = DispatchQueue(label: "work.12306.xstats.speedtest.tcp", qos: .utility)

    private static func connect(host: String, port: UInt16, timeout: TimeInterval) async -> Double? {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = Int(timeout.rounded(.up))
        options.noDelay = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port,
                                      using: NWParameters(tls: nil, tcp: options))
        let clock = ContinuousClock()
        let start = clock.now
        let once = ResumeOnce()
        let milliseconds: Double? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.attach(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.resume(Self.elapsed(from: start, clock: clock))
                    case .failed, .cancelled:
                        once.resume(nil)
                    case .waiting:
                        // 路由不可达、端口被拒：不再等超时，直接算这次失败
                        once.resume(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                // connectionTimeout 在个别情况下不触发状态变化，兜一个自己的超时
                queue.asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
            }
        } onCancel: {
            once.resume(nil)
        }
        connection.cancel()
        return milliseconds
    }

    private static func elapsed(from start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
        let duration = clock.now - start
        return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

/// 状态回调、超时与取消都可能同时到达，续体只能恢复一次
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Double?, Never>?
    private var done = false
    private var pending: Double??

    func attach(_ continuation: CheckedContinuation<Double?, Never>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Double?) {
        lock.lock()
        guard !done else { return lock.unlock() }
        done = true
        guard let continuation else {
            // 续体还没挂上（取消可能先到），先记下结果
            pending = .some(value)
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
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

/// 下载与上传测速：边传边算，达到上限就掐断连接，不会把整份文件收完
public enum ThroughputProbe {
    /// 开头的建连、慢启动不计入速度
    static let warmup: Double = 0.5

    public static func download(_ url: URL, limit: SpeedLimit,
                                progress: @escaping @Sendable (Double, Int) -> Void = { _, _ in }) async -> SpeedResult? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(limit.bytes - 1)", forHTTPHeaderField: "Range")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return await SpeedMeter(limit: limit, progress: progress).run(request: request, uploadBytes: nil).result
    }

    public static func upload(_ url: URL, bytes: Int, limit: SpeedLimit,
                              progress: @escaping @Sendable (Double, Int) -> Void = { _, _ in }) async -> SpeedResult? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return await SpeedMeter(limit: limit, progress: progress).run(request: request, uploadBytes: bytes).result
    }

    /// 反复请求同一个地址直到用满上限，并读出响应头（Cloudflare 单次最多给 25 MB，
    /// 而且边缘节点信息就在响应头里）
    static func downloadRepeatedly(_ url: URL, limit: SpeedLimit,
                                   progress: @escaping @Sendable (Double, Int) -> Void = { _, _ in })
        async -> (result: SpeedResult?, headers: [String: String]) {
        var request = URLRequest(url: url)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return await SpeedMeter(limit: limit, progress: progress).run(request: request, uploadBytes: nil, repeats: true)
    }
}

/// 统计传输速度：记录起点与热身之后的字节数，达到上限就取消任务
private final class SpeedMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: SpeedLimit
    private let progress: @Sendable (Double, Int) -> Void
    private let clock = ContinuousClock()
    private let lock = NSLock()

    private var start: ContinuousClock.Instant?
    /// 热身结束时的时间与字节数，速度从这里开始算
    private var mark: (time: ContinuousClock.Instant, bytes: Int)?
    private var bytes = 0
    private var headers: [String: String] = [:]
    private var finished = false
    private var continuation: CheckedContinuation<(SpeedResult?, [String: String]), Never>?
    private var task: URLSessionTask?
    /// 单次请求给不满上限时（Cloudflare 一次最多 25 MB）继续下一次
    private var repeats = false
    private var session: URLSession?
    private var request: URLRequest?

    init(limit: SpeedLimit, progress: @escaping @Sendable (Double, Int) -> Void) {
        self.limit = limit
        self.progress = progress
    }

    func run(request: URLRequest, uploadBytes: Int?,
             repeats: Bool = false) async -> (result: SpeedResult?, headers: [String: String]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = limit.seconds + 10
        configuration.httpAdditionalHeaders = ["User-Agent": "XStats"]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        prepare(session: session, request: request, repeats: repeats)

        let pair: (SpeedResult?, [String: String]) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                start = clock.now
                lock.unlock()
                let task: URLSessionTask
                if let uploadBytes {
                    task = session.uploadTask(with: request, from: Data(count: uploadBytes))
                } else {
                    task = session.dataTask(with: request)
                }
                lock.lock()
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            finish(cancelled: true)
        }
        return (pair.0, pair.1)
    }

    /// 记下会话与请求，续传时还要再发一次（同步方法，异步上下文里不能直接拿锁）
    private func prepare(session: URLSession, request: URLRequest, repeats: Bool) {
        lock.lock()
        self.session = session
        self.request = request
        self.repeats = repeats
        lock.unlock()
    }

    // MARK: 回调

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            lock.lock()
            headers = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value in
                (key as? String).map { ($0.lowercased(), String(describing: value)) }
            })
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        advance(by: data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        advance(by: Int(bytesSent))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil, continueIfNeeded() { return }
        finish(cancelled: false)
    }

    /// 还没到上限、这次请求又正常结束：接着发下一次，把测量凑满
    private func continueIfNeeded() -> Bool {
        lock.lock()
        guard repeats, !finished, let start, let session, let request, bytes > 0,
              bytes < limit.bytes, Self.seconds(from: start, to: clock.now) < limit.seconds else {
            lock.unlock()
            return false
        }
        let next = session.dataTask(with: request)
        task = next
        lock.unlock()
        next.resume()
        return true
    }

    // MARK: 计算

    private func advance(by count: Int) {
        lock.lock()
        bytes += count
        guard let start, !finished else { return lock.unlock() }
        let now = clock.now
        let seconds = Self.seconds(from: start, to: now)
        if mark == nil, seconds >= ThroughputProbe.warmup { mark = (now, bytes) }
        let (speed, used) = (rate(now: now), bytes)
        let reachedLimit = bytes >= limit.bytes || seconds >= limit.seconds
        lock.unlock()
        progress(speed, used)
        if reachedLimit { finish(cancelled: false) }
    }

    /// 热身之后的平均速度；还没过热身期就用全程平均，让界面上的数字先动起来
    private func rate(now: ContinuousClock.Instant) -> Double {
        guard let start else { return 0 }
        let from = mark?.time ?? start
        let base = mark?.bytes ?? 0
        let seconds = Self.seconds(from: from, to: now)
        guard seconds > 0.05 else { return 0 }
        return Double(bytes - base) * 8 / seconds
    }

    private func finish(cancelled: Bool) {
        lock.lock()
        guard !finished, let start else { return lock.unlock() }
        finished = true
        let now = clock.now
        let result: SpeedResult?
        if cancelled || bytes == 0 {
            result = nil
        } else {
            let from = mark?.time ?? start
            let seconds = Self.seconds(from: from, to: now)
            let measured = bytes - (mark?.bytes ?? 0)
            result = seconds > 0.05 && measured > 0
                ? SpeedResult(bitsPerSecond: Double(measured) * 8 / seconds, bytes: bytes,
                              seconds: Self.seconds(from: start, to: now))
                : nil
        }
        let continuation = self.continuation
        let headers = self.headers
        let task = self.task
        self.continuation = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(returning: (result, headers))
    }

    private static func seconds(from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> Double {
        let duration = to - from
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
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

    public static func run(limit: SpeedLimit,
                           stage: @escaping @Sendable (Stage) -> Void = { _ in },
                           progress: @escaping @Sendable (Double, Int) -> Void = { _, _ in }) async -> BroadbandResult {
        var result = BroadbandResult()

        stage(.latency)
        let (samples, headers) = await latency()
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
        let (download, downloadHeaders) = await ThroughputProbe.downloadRepeatedly(url, limit: limit, progress: progress)
        result.download = download
        result.totalBytes += download?.bytes ?? 0
        result.colo = result.colo ?? downloadHeaders["cf-meta-colo"] ?? downloadHeaders["colo"]
        guard !Task.isCancelled else { return result }

        stage(.upload)
        let uploadBytes = min(limit.bytes, uploadMegabytes * 1024 * 1024)
        let upload = await ThroughputProbe.upload(upURL, bytes: uploadBytes, limit: limit, progress: progress)
        result.upload = upload
        result.totalBytes += upload?.bytes ?? 0
        return result
    }

    /// 连续请求空响应，用往返时间当延迟；第一次要建连、握手，不计入
    private static func latency() async -> ([Double], [String: String]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.httpAdditionalHeaders = ["User-Agent": "XStats"]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: downURL.absoluteString + "0")!
        let clock = ContinuousClock()
        var samples: [Double] = []
        var headers: [String: String] = [:]
        for index in 0..<latencySamples {
            if Task.isCancelled { break }
            let start = clock.now
            guard let (_, response) = try? await session.data(from: url) else { continue }
            let duration = clock.now - start
            // 前两次在建连、握手，不算延迟
            if index < 2 {
                headers = Dictionary(uniqueKeysWithValues: ((response as? HTTPURLResponse)?.allHeaderFields ?? [:])
                    .compactMap { key, value in (key as? String).map { ($0.lowercased(), String(describing: value)) } })
                continue
            }
            samples.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
        }
        return (samples, headers)
    }
}
