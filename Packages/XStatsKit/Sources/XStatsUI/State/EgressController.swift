import AppKit
import Foundation
import Metrics
import Observation

/// 出口与分流检测：只在窗口打开时工作。打开时没有结果、结果过期或网络变了就检测一次，
/// 窗口开着期间每隔几秒读一次代理环境（只读系统配置，不发请求），隧道、代理或网卡变化后自动重测
@MainActor
@Observable
public final class EgressController {
    public struct Report: Codable, Equatable, Sendable {
        public var date: Date
        public var environment: ProxyEnvironment
        public var hits: [EgressHit]
        /// 出口 IP → cleanip.io 给出的归属地
        public var geo: [String: EgressGeo]
    }

    public private(set) var report: Report?
    public private(set) var analysis: EgressAnalysis?
    /// 实时读到的代理环境；与报告里的不同说明网络已经变了
    public private(set) var environment: ProxyEnvironment?
    public private(set) var isChecking = false
    /// 本次检测已完成的测量数，总数见 `EgressProber.jobCount`
    public private(set) var progress = 0

    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var geoCache: [String: (geo: EgressGeo, date: Date)] = [:]

    private static let cacheKey = "egressReport2"
    /// 超过这个时间的结果，打开窗口时重新检测
    static let staleAfter: TimeInterval = 10 * 60
    static let geoLifetime: TimeInterval = 60 * 60

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let report = try? JSONDecoder().decode(Report.self, from: data) {
            apply(report)
        }
    }

    /// 网络环境与上次检测时不同
    public var networkChanged: Bool {
        guard let report, let environment else { return false }
        return report.environment.signature != environment.signature
    }

    func windowDidOpen() {
        startWatching()
    }

    func windowDidClose() {
        watchTask?.cancel()
        watchTask = nil
    }

    func check() {
        guard !isChecking else { return }
        isChecking = true
        progress = 0
        Task {
            let environment = await Self.readEnvironment()
            self.environment = environment
            let hits = await EgressProber.measure(interfaceName: environment.physicalInterface) { done in
                Task { @MainActor in self.progress = done }
            }
            let analysis = EgressAnalysis.evaluate(hits, environment: environment)
            let geo = await lookUpGeo(hits: hits, analysis: analysis, interfaceName: environment.physicalInterface)
            let report = Report(date: Date(), environment: environment, hits: hits, geo: geo)
            apply(report)
            UserDefaults.standard.set(try? JSONEncoder().encode(report), forKey: Self.cacheKey)
            isChecking = false
        }
    }

    private func apply(_ report: Report) {
        self.report = report
        analysis = EgressAnalysis.evaluate(report.hits, environment: report.environment)
    }

    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                let environment = await Self.readEnvironment()
                guard !Task.isCancelled, let self else { return }
                if environment != self.environment { self.environment = environment }
                let stale = self.report.map { Date().timeIntervalSince($0.date) > Self.staleAfter } ?? true
                // 刚打开：没有结果或过期了就测；开着期间：网络变了就重测
                if !self.isChecking, (first && stale) || self.networkChanged {
                    self.check()
                }
                first = false
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private static func readEnvironment() async -> ProxyEnvironment {
        let apps = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        return await Task.detached {
            ProxyEnvironmentReader.read(details: NetworkDetailsReader.read(), runningAppNames: apps)
        }.value
    }

    // MARK: 归属地

    /// 原始出口经物理网卡查，代理出口经系统代理查；cleanip.io 只查请求方自己，查到的就是那条路线的出口。
    /// 同一个 IP 一小时内不重复查
    private func lookUpGeo(hits: [EgressHit], analysis: EgressAnalysis, interfaceName: String?) async -> [String: EgressGeo] {
        var wanted: [(route: EgressRoute, ipv6: Bool, expected: String)] = []
        for address in analysis.rawAddresses {
            let ipv6 = address.contains(":")
            if !wanted.contains(where: { $0.route == .interface && $0.ipv6 == ipv6 }) {
                wanted.append((.interface, ipv6, address))
            }
        }
        if let proxied = analysis.exits.first(where: { $0.path != .direct }) {
            wanted.append((.system, proxied.ip.contains(":"), proxied.ip))
        }

        var result: [String: EgressGeo] = [:]
        let now = Date()
        var lookups: [(route: EgressRoute, ipv6: Bool)] = []
        for item in wanted {
            if let cached = geoCache[item.expected], now.timeIntervalSince(cached.date) < Self.geoLifetime {
                result[item.expected] = cached.geo
            } else {
                lookups.append((item.route, item.ipv6))
            }
        }
        let found = await withTaskGroup(of: (ip: String, geo: EgressGeo)?.self) { group in
            for lookup in lookups {
                group.addTask { await EgressProber.geo(route: lookup.route, ipv6: lookup.ipv6, interfaceName: interfaceName) }
            }
            var found: [(ip: String, geo: EgressGeo)] = []
            for await item in group { if let item { found.append(item) } }
            return found
        }
        for item in found {
            result[item.ip] = item.geo
            geoCache[item.ip] = (item.geo, now)
        }
        return result
    }
}
