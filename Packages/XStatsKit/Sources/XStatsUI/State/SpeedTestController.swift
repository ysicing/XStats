import Foundation
import Localization
import Metrics
import Observation

/// 网络测速：本机宽带、国内分省三网延迟、全球节点、全球探针看目标。
/// 四块互相独立，各自可以单独跑、单独停；下载类测试有明确的时间与流量上限
@MainActor
@Observable
public final class SpeedTestController {
    // MARK: 本机宽带

    public private(set) var broadband: BroadbandResult?
    public private(set) var broadbandDate: Date?
    public private(set) var broadbandStage: BroadbandTest.Stage?
    /// 测试进行中的实时速率，bit/s
    public private(set) var liveBitsPerSecond: Double = 0
    public var isTestingBroadband: Bool { broadbandStage != nil }

    // MARK: 国内分省三网

    public private(set) var chinaLatency: [String: LatencyResult] = [:]
    public private(set) var chinaDate: Date?
    public private(set) var chinaProgress = 0
    public private(set) var isTestingChina = false

    // MARK: 全球节点

    public private(set) var globalLatency: [String: LatencyResult] = [:]
    public private(set) var globalSpeed: [String: SpeedResult] = [:]
    public private(set) var globalDate: Date?
    public private(set) var globalProgress = 0
    public private(set) var isTestingGlobal = false
    /// 正在做下载测速的节点
    public private(set) var downloadingNode: String?

    // MARK: 全球探针

    /// 要探测的域名与探针数量：界面输入框绑在这里
    public var globalpingTarget = ""
    public var globalpingProbes = 20
    public private(set) var globalpingRun: GlobalpingRun?
    public private(set) var globalpingError: String?
    public private(set) var isProbing = false

    /// 本次打开窗口以来用掉的流量
    public private(set) var bytesUsed = 0

    @ObservationIgnored private var broadbandTask: Task<Void, Never>?
    @ObservationIgnored private var chinaTask: Task<Void, Never>?
    @ObservationIgnored private var globalTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private let settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    var limit: SpeedLimit { settings.speedTestBudget.limit }

    /// 关窗时停掉所有还在跑的测试，别让它继续占带宽
    func windowDidClose() {
        cancelAll()
    }

    public func cancelAll() {
        broadbandTask?.cancel()
        chinaTask?.cancel()
        globalTask?.cancel()
        downloadTask?.cancel()
        probeTask?.cancel()
        broadbandStage = nil
        isTestingChina = false
        isTestingGlobal = false
        downloadingNode = nil
        isProbing = false
        liveBitsPerSecond = 0
    }

    // MARK: 本机宽带

    public func runBroadband() {
        if isTestingBroadband {
            broadbandTask?.cancel()
            stopBroadband()
            return
        }
        broadbandStage = .latency
        liveBitsPerSecond = 0
        broadbandTask = Task { [limit] in
            let result = await BroadbandTest.run(limit: limit) { stage in
                Task { @MainActor [weak self] in self?.broadbandStage = stage; self?.liveBitsPerSecond = 0 }
            } progress: { speed, _ in
                Task { @MainActor [weak self] in self?.liveBitsPerSecond = speed }
            }
            guard !Task.isCancelled else { return stopBroadband() }
            broadband = result
            broadbandDate = Date()
            bytesUsed += result.totalBytes
            broadbandStage = nil
            liveBitsPerSecond = 0
        }
    }

    private func stopBroadband() {
        broadbandStage = nil
        liveBitsPerSecond = 0
    }

    // MARK: 国内分省三网

    /// 93 个省级节点只做 TCP 建连计时，不下载数据
    public func runChina() {
        if isTestingChina {
            chinaTask?.cancel()
            isTestingChina = false
            return
        }
        isTestingChina = true
        chinaProgress = 0
        chinaTask = Task {
            let nodes = ChinaNode.all
            await withTaskGroup(of: (String, LatencyResult).self) { group in
                var next = 0
                while next < min(Self.concurrency, nodes.count) {
                    group.addTask { [node = nodes[next]] in
                        (node.id, await TCPLatencyProbe.measure(host: node.host, port: node.port,
                                                                attempts: 2, timeout: 3))
                    }
                    next += 1
                }
                for await (id, result) in group {
                    chinaLatency[id] = result
                    chinaProgress += 1
                    if Task.isCancelled { break }
                    if next < nodes.count {
                        group.addTask { [node = nodes[next]] in
                            (node.id, await TCPLatencyProbe.measure(host: node.host, port: node.port,
                                                                    attempts: 2, timeout: 3))
                        }
                        next += 1
                    }
                }
                group.cancelAll()
            }
            chinaDate = Date()
            isTestingChina = false
        }
    }

    /// 三网各自的延迟中位数，用来一眼看出哪张网更顺
    public func chinaMedian(_ carrier: ChinaCarrier) -> Double? {
        let values = ChinaNode.all.filter { $0.carrier == carrier }
            .compactMap { chinaLatency[$0.id]?.best }
            .sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    public func chinaReachable(_ carrier: ChinaCarrier) -> (reachable: Int, total: Int) {
        let nodes = ChinaNode.all.filter { $0.carrier == carrier }
        let measured = nodes.compactMap { chinaLatency[$0.id] }
        return (measured.filter(\.isReachable).count, nodes.count)
    }

    // MARK: 全球节点

    public func runGlobal() {
        if isTestingGlobal {
            globalTask?.cancel()
            isTestingGlobal = false
            return
        }
        isTestingGlobal = true
        globalProgress = 0
        globalTask = Task {
            let nodes = GlobalNode.all
            await withTaskGroup(of: (String, LatencyResult).self) { group in
                var next = 0
                while next < min(Self.concurrency, nodes.count) {
                    group.addTask { [node = nodes[next]] in
                        (node.id, await TCPLatencyProbe.measure(host: node.host, port: node.port,
                                                                attempts: 3, timeout: 4))
                    }
                    next += 1
                }
                for await (id, result) in group {
                    globalLatency[id] = result
                    globalProgress += 1
                    if Task.isCancelled { break }
                    if next < nodes.count {
                        group.addTask { [node = nodes[next]] in
                            (node.id, await TCPLatencyProbe.measure(host: node.host, port: node.port,
                                                                    attempts: 3, timeout: 4))
                        }
                        next += 1
                    }
                }
                group.cancelAll()
            }
            globalDate = Date()
            isTestingGlobal = false
        }
    }

    /// 单个节点的下载测速，手动触发，一次只跑一个
    public func download(_ node: GlobalNode) {
        if downloadingNode == node.id {
            downloadTask?.cancel()
            downloadingNode = nil
            liveBitsPerSecond = 0
            return
        }
        downloadTask?.cancel()
        downloadingNode = node.id
        liveBitsPerSecond = 0
        downloadTask = Task { [limit] in
            let result = await ThroughputProbe.download(node.downloadURL, limit: limit) { speed, _ in
                Task { @MainActor [weak self] in self?.liveBitsPerSecond = speed }
            }
            guard !Task.isCancelled else {
                downloadingNode = nil
                liveBitsPerSecond = 0
                return
            }
            if let result {
                globalSpeed[node.id] = result
                bytesUsed += result.bytes
            }
            downloadingNode = nil
            liveBitsPerSecond = 0
        }
    }

    // MARK: 全球探针

    /// 匿名调用 Globalping，额度按这台 Mac 的 IP 计算
    public func runGlobalping() {
        let (target, probes) = (globalpingTarget, globalpingProbes)
        if isProbing {
            probeTask?.cancel()
            isProbing = false
            return
        }
        isProbing = true
        globalpingError = nil
        probeTask = Task {
            do {
                let run = try await GlobalpingClient.ping(target: target, probes: probes)
                guard !Task.isCancelled else {
                    isProbing = false
                    return
                }
                globalpingRun = run
            } catch let failure as GlobalpingClient.Failure {
                globalpingError = Self.message(for: failure)
            } catch {
                globalpingError = Task.isCancelled ? nil : error.localizedDescription
            }
            isProbing = false
        }
    }

    private static func message(for failure: GlobalpingClient.Failure) -> String {
        switch failure {
        case .invalidTarget: tr("请填写一个域名，例如 example.com")
        case .rateLimited(let seconds):
            seconds.map { tr("这个小时的免费额度用完了，\($0 / 60 + 1) 分钟后可以再试") }
                ?? tr("这个小时的免费额度用完了，过一会儿再试")
        case .timeout: tr("探针一直没有返回结果，稍后再试")
        case .http(let code): tr("Globalping 返回了错误（HTTP \(code)）")
        }
    }

    /// 同时进行的建连数：太多会互相挤占，延迟数字会偏大
    private static let concurrency = 12
}
