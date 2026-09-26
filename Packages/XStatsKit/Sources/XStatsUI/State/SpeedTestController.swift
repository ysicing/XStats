// OpenStats source retained under MIT; XStats adaptations Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import Foundation
import Localization
import Metrics
import Observation

/// 网络测速：本机宽带、国内分省三网延迟、全球节点、全球探针看目标。
/// 四块互相独立，各自可以单独跑、单独停；下载类测试有明确的时间与流量上限。
///
/// 开着 VPN / 代理时，测速按设置走直连（绑定物理网卡绕开它）或经代理；
/// 国内三网只允许做 TCP 建连计时，经代理时握手由本机代理应答、测不出东西，所以始终直连
@MainActor
@Observable
public final class SpeedTestController {
    // MARK: 线路

    /// 当前网络的代理环境；开着 VPN / 代理时界面上给出线路选择
    public private(set) var environment: ProxyEnvironment?
    public var hasProxy: Bool { environment?.hasProxy == true }

    /// 代理的名字：隧道的服务名（例如 Surge），其次是正在运行的代理软件
    public var proxyName: String {
        environment?.tunnelName ?? environment?.apps.first ?? tr("代理")
    }

    // MARK: 本机宽带

    public private(set) var broadband: BroadbandResult?
    public private(set) var broadbandDate: Date?
    public private(set) var broadbandStage: BroadbandTest.Stage?
    /// 开着代理时这次走的线路，界面上标出来；没有代理时为 nil
    public private(set) var broadbandRoute: SpeedRoute?
    /// 测试进行中的实时速率，bit/s
    public private(set) var liveBitsPerSecond: Double = 0
    public var isTestingBroadband: Bool { broadbandStage != nil }

    // MARK: 国内分省三网

    public private(set) var chinaLatency: [String: LatencyResult] = [:]
    public private(set) var chinaDate: Date?
    public private(set) var chinaProgress = 0
    public private(set) var isTestingChina = false
    public private(set) var chinaRoute: SpeedRoute?
    /// 绕不开 VPN、没法测时的说明
    public private(set) var chinaNotice: String?

    // MARK: 全球节点

    public private(set) var globalLatency: [String: LatencyResult] = [:]
    public private(set) var globalSpeed: [String: SpeedResult] = [:]
    public private(set) var globalDate: Date?
    public private(set) var globalProgress = 0
    public private(set) var isTestingGlobal = false
    /// 全球节点延迟与下载测速走的线路
    public private(set) var globalRoute: SpeedRoute?
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
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var details: NetworkDetails?
    @ObservationIgnored private let settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    var limit: SpeedLimit { settings.speedTestBudget.limit }

    /// 窗口开着时每隔几秒读一次代理环境，VPN 开关后线路选择跟着出现或消失
    func windowDidOpen() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshEnvironment()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// 关窗时停掉所有还在跑的测试，别让它继续占带宽
    func windowDidClose() {
        watchTask?.cancel()
        cancelAll()
    }

    /// 换了线路，之前的结果属于另一条线路，全部清掉并停下正在跑的测试
    public func routeDidChange() {
        cancelAll()
        broadband = nil
        broadbandDate = nil
        broadbandRoute = nil
        chinaLatency = [:]
        chinaDate = nil
        chinaRoute = nil
        chinaNotice = nil
        globalLatency = [:]
        globalSpeed = [:]
        globalDate = nil
        globalRoute = nil
    }

    private func refreshEnvironment() async {
        let apps = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        let (details, environment) = await Task.detached {
            let details = NetworkDetailsReader.read()
            return (details, ProxyEnvironmentReader.read(details: details, runningAppNames: apps))
        }.value
        self.details = details
        if environment != self.environment { self.environment = environment }
    }

    /// 定下这次测速走哪条路。每次开测前都重读网络环境，刚开关 VPN 也不会走错
    private func resolvePath(_ route: SpeedRoute) async -> SpeedPath {
        await refreshEnvironment()
        guard let details, let environment else { return .system }
        return await SpeedPath.make(route: route, details: details, environment: environment)
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
        broadbandTask = Task { [self, limit, route = settings.speedTestRoute] in
            let path = await resolvePath(route)
            guard !Task.isCancelled else { return }
            let result = await BroadbandTest.run(limit: limit, path: path) { stage in
                Task { @MainActor [weak self] in self?.broadbandStage = stage; self?.liveBitsPerSecond = 0 }
            } progress: { speed, _ in
                Task { @MainActor [weak self] in self?.liveBitsPerSecond = speed }
            }
            guard !Task.isCancelled else { return }
            broadband = result
            broadbandRoute = path.route
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

    /// 93 个省级节点只做 TCP 建连计时，不下载数据。
    /// 始终绑定物理网卡直连测：经代理时握手由本机代理当场应答，只剩零点几毫秒，与节点远近无关
    public func runChina() {
        if isTestingChina {
            chinaTask?.cancel()
            isTestingChina = false
            return
        }
        isTestingChina = true
        chinaProgress = 0
        chinaLatency = [:]
        chinaTask = Task {
            let path = await resolvePath(.direct)
            guard !Task.isCancelled else { return }
            guard !path.isProxied else {
                chinaNotice = tr("VPN 不允许绕开它直连，TCP 建连会被本机代理提前应答，测不出真实延迟。关掉 VPN 再测")
                chinaDate = nil
                isTestingChina = false
                return
            }
            chinaNotice = nil
            let nodes = ChinaNode.all
            await measure(nodes, concurrency: Self.concurrency) { node in
                // 远距离线路偶尔丢一个握手包，多给一次机会、超时放宽一点
                await TCPLatencyProbe.measure(host: node.host, port: node.port, path: path, attempts: 3, timeout: 4)
            } done: { node, result in
                chinaLatency[node.id] = result
                chinaProgress += 1
            }
            guard !Task.isCancelled else { return }
            chinaRoute = path.route
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

    /// 直连时用 TCP 建连计时；经代理时握手由本机代理应答，改用 HTTP 往返计时
    public func runGlobal() {
        if isTestingGlobal {
            globalTask?.cancel()
            isTestingGlobal = false
            return
        }
        isTestingGlobal = true
        globalProgress = 0
        globalLatency = [:]
        globalTask = Task { [route = settings.speedTestRoute] in
            let path = await resolvePath(route)
            guard !Task.isCancelled else { return }
            await measure(GlobalNode.all, concurrency: Self.concurrency) { node in
                path.isProxied
                    ? await HTTPLatencyProbe.measure(node.downloadURL, path: path, samples: 3, timeout: 5)
                    : await TCPLatencyProbe.measure(host: node.host, port: node.port, path: path, attempts: 3, timeout: 4)
            } done: { node, result in
                globalLatency[node.id] = result
                globalProgress += 1
            }
            guard !Task.isCancelled else { return }
            globalRoute = path.route
            globalDate = Date()
            isTestingGlobal = false
        }
    }

    /// 限定并发地逐个测量节点，每测完一个就回到主线程交结果；取消后不再发新的
    func measure<Node: Sendable>(_ nodes: [Node], concurrency: Int,
                                         _ probe: @escaping @Sendable (Node) async -> LatencyResult,
                                         done: (Node, LatencyResult) -> Void) async {
        await withTaskGroup(of: (Node, LatencyResult).self) { group in
            var next = 0
            while next < min(concurrency, nodes.count) {
                group.addTask { [node = nodes[next]] in (node, await probe(node)) }
                next += 1
            }
            for await (node, result) in group {
                if Task.isCancelled { break }
                done(node, result)
                if next < nodes.count {
                    group.addTask { [node = nodes[next]] in (node, await probe(node)) }
                    next += 1
                }
            }
            group.cancelAll()
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
        downloadTask = Task { [self, limit, route = settings.speedTestRoute] in
            let path = await resolvePath(route)
            guard !Task.isCancelled else { return }
            let result = await ThroughputProbe.download(node.downloadURL, limit: limit, path: path) { speed, _ in
                Task { @MainActor [weak self] in self?.liveBitsPerSecond = speed }
            }
            guard !Task.isCancelled else { return }
            if let result {
                globalSpeed[node.id] = result
                globalRoute = path.route
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
