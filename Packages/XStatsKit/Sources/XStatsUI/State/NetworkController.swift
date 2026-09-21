import Foundation
import HelperShared
import Metrics
import Observation

/// 一次连接探测：latency 为往返毫秒数，nil 表示超时或不可达
public struct ProbeSample: Sendable, Equatable {
    public let latency: Double?
}

/// 网络详情：接口与地址、公网 IP、连接探测、各进程流量与 DNS 配置
@MainActor
@Observable
public final class NetworkController {
    /// 探测格子显示最近 60 次；前台每秒一次，也就是最近 60 秒
    public static let probeCapacity = 60

    public private(set) var details: NetworkDetails?
    /// 公网 IP 信息按地址族各存一份：两份都含 IPv4 与 IPv6 地址，归属地、纯净度等是各自那个地址的
    public private(set) var publicResults: [IPFamily: PublicAddresses] = [:]
    /// 界面上当前看的是哪一族；只有一族时自动跟着
    public var publicFamily: IPFamily = .v4
    /// 当前地址族的结果；所选那族没有时退到另一族
    public var publicAddresses: PublicAddresses? {
        publicResults[publicFamily] ?? publicResults[publicFamily == .v4 ? .v6 : .v4]
    }
    /// 两族都有归属地结果时才提供切换
    public var hasDualStack: Bool {
        publicResults[.v4] != nil && publicResults[.v6] != nil
    }
    /// 界面上标注的地址族：双栈时显示，单栈不显示
    public var shownFamily: IPFamily? {
        guard hasDualStack else { return nil }
        return publicResults[publicFamily] != nil ? publicFamily : (publicFamily == .v4 ? .v6 : .v4)
    }
    /// 仅用于界面转圈：有缓存可显示时不转圈，后台悄悄核对
    public private(set) var isLookingUpPublic = false
    /// 仅用于重入保护，与转圈状态相反——有缓存时也必须挡住并发查询，
    /// 否则两个 Task 会各发三次请求、并发写缓存，失败结果可能覆盖好结果
    @ObservationIgnored private var isFetchingPublic = false
    public private(set) var probes = History<ProbeSample>(capacity: probeCapacity)
    public private(set) var processes: [NetworkProcessUsage] = []
    /// 各进程流量的平滑排行，列表按它排序而不是按瞬时速率
    @ObservationIgnored private var processRanking = ActivityRanking()

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var probedAddress: String?
    @ObservationIgnored private var lastPublicLookup: (date: Date, localIPv4: [String])?
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var wantsDetail = false
    @ObservationIgnored private var inMenuBar = false
    /// 正在运行的探测是否为前台频率；前后台切换时重启循环，不必等完后台的长间隔
    @ObservationIgnored private var probingForeground: Bool?

    /// 网络详情打开时每秒探测一次；详情关闭、只在菜单栏显示网速时低频探测
    static let foregroundProbeSeconds = 1
    static let backgroundProbeSeconds = 10

    /// 上次查到的公网 IP 信息：点开弹窗时先显示它，只有超过 7 天或公网 IP 变了才重新查归属地
    private struct PublicCache: Codable {
        var results: [String: PublicAddresses]
        var geoDates: [String: Date]
    }
    static let geoCacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// 第 4 版起只有 cleanip.io 一个数据源，旧版本缓存里可能是别的数据源的结果，不再读取
    private static let cacheKey = "publicAddressCache4"

    /// 用户按过“重置统计”后的累计流量基线：界面显示 当前累计 − 基线。
    /// 随开机时间一起保存，重启后系统计数器归零、基线作废，自动回到开机后累计
    public struct TrafficBaseline: Codable, Equatable, Sendable {
        public var download: UInt64
        public var upload: UInt64
        public var date: Date
        var bootTime: TimeInterval?
    }
    public private(set) var trafficBaseline: TrafficBaseline?
    private static let trafficBaselineKey = "trafficBaseline"
    private static let bootTime: TimeInterval? = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        return sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 ? TimeInterval(boot.tv_sec) : nil
    }()

    init(settings: AppSettings) {
        self.settings = settings
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cache = try? JSONDecoder().decode(PublicCache.self, from: data), settings.publicIPLookup {
            publicResults = Dictionary(uniqueKeysWithValues: cache.results.compactMap { key, value in IPFamily(rawValue: key).map { ($0, value) } })
        }
        if let data = UserDefaults.standard.data(forKey: Self.trafficBaselineKey),
           let baseline = try? JSONDecoder().decode(TrafficBaseline.self, from: data),
           baseline.bootTime == Self.bootTime {
            trafficBaseline = baseline
        }
    }

    // MARK: 流量统计

    /// 从现在起重新累计上传与下载：把当前计数器记成基线
    public func resetTraffic(_ rate: NetworkRate) {
        let baseline = TrafficBaseline(download: rate.totalDownloaded, upload: rate.totalUploaded, date: Date(), bootTime: Self.bootTime)
        trafficBaseline = baseline
        UserDefaults.standard.set(try? JSONEncoder().encode(baseline), forKey: Self.trafficBaselineKey)
    }

    /// 改回开机后的累计
    public func clearTrafficBaseline() {
        trafficBaseline = nil
        UserDefaults.standard.removeObject(forKey: Self.trafficBaselineKey)
    }

    /// 扣掉基线后的累计流量；计数器比基线小（接口变动）时按 0 算
    public func trafficTotals(_ rate: NetworkRate) -> (download: UInt64, upload: UInt64) {
        guard let baseline = trafficBaseline else { return (rate.totalDownloaded, rate.totalUploaded) }
        return (rate.totalDownloaded >= baseline.download ? rate.totalDownloaded - baseline.download : 0,
                rate.totalUploaded >= baseline.upload ? rate.totalUploaded - baseline.upload : 0)
    }

    // MARK: 探测目标

    var probeAddress: String? {
        settings.probeTarget.address(router: details?.physical?.router)
    }

    // MARK: 生命周期

    /// 网络详情打开时按设置的间隔探测；只在菜单栏显示网络项时按 10 秒低频探测（可在设置里关闭），其余时间停止
    func setVisibility(inMenuBar: Bool, detailVisible: Bool) {
        self.inMenuBar = inMenuBar
        wantsDetail = detailVisible
        applyDetailState()
        applyProbeState()
    }

    private func applyProbeState() {
        let foreground = wantsDetail
        let shouldRun = settings.probeEnabled && !isPaused
            && (foreground || (inMenuBar && settings.probeInBackground))
        guard shouldRun else {
            probeTask?.cancel()
            probeTask = nil
            probingForeground = nil
            return
        }
        guard probeTask == nil || probingForeground != foreground else { return }
        probeTask?.cancel()
        probingForeground = foreground
        startProbing()
    }

    /// 探测目标或间隔变化时重新开始，历史清空避免混入不同目标的数据
    func restartProbing() {
        guard probeTask != nil else { return }
        probeTask?.cancel()
        probes = History(capacity: Self.probeCapacity)
        startProbing()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        applyProbeState()
        applyDetailState()
    }

    /// 网络详情打开时每 2 秒刷新接口信息与进程流量，关闭后停止
    private func applyDetailState() {
        let shouldRun = wantsDetail && !isPaused
        guard shouldRun != (detailTask != nil) else { return }
        detailTask?.cancel()
        detailTask = nil
        // 关闭时保留上次的进程列表，再次打开时不会先闪一下空白
        guard shouldRun else { return }
        detailTask = Task { [weak self] in
            var sampler = NetworkProcessSampler()
            var tick = 0
            while !Task.isCancelled {
                // 接口信息每 4 秒读一次，进程流量每 2 秒
                if tick % 2 == 0 {
                    let details = await Task.detached { NetworkDetailsReader.read() }.value
                    guard !Task.isCancelled, let self else { return }
                    if details != self.details { self.details = details }
                    if tick == 0 { self.lookUpPublicAddressesIfStale() }
                }
                let (usage, next) = await Task.detached { [sampler] in
                    var copy = sampler
                    let usage = copy.sample()
                    return (usage, copy)
                }.value
                sampler = next
                guard !Task.isCancelled, let self else { return }
                self.processes = self.rankedProcesses(usage)
                tick += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshDetails() async {
        details = await Task.detached { NetworkDetailsReader.read() }.value
    }

    // MARK: 公网 IP

    /// 先只取公网地址（Cloudflare，便宜且不限额），再按地址族各向 cleanip.io 查一次（锁定 IPv4 / IPv6 连接，
    /// 因为它只查请求方自己）：地址没变、结果不满 7 天的那一族沿用缓存，否则重新查并写回缓存。
    /// `force` 为真时（用户点了刷新）两族都重查
    func lookUpPublicAddresses(force: Bool = false) {
        guard settings.publicIPLookup, !isFetchingPublic else { return }
        isFetchingPublic = true
        // 有缓存可显示时不转圈，后台悄悄核对
        isLookingUpPublic = publicResults.isEmpty || force
        let localIPv4 = details?.physical?.ipv4 ?? []
        Task {
            // 无论正常结束、抛出还是被取消都要放开重入锁，否则查询会永久卡死
            defer { isFetchingPublic = false }
            let base = await PublicAddressLookup.fetch(includeGeo: false)
            let cached = Self.loadCache()
            let now = Date()

            @MainActor func resolve(_ family: IPFamily, ip: String?) async -> PublicAddresses? {
                guard let ip else { return nil }
                let previous = cached?.results[family.rawValue]
                let sameAddress = previous.map { ($0.queriedAddress ?? (family == .v4 ? $0.ipv4 : $0.ipv6)) == ip } ?? false
                // 上次什么都没查到的不算缓存，这次重查
                if !force, sameAddress, let previous, previous.hasLookupData,
                   let date = cached?.geoDates[family.rawValue], now.timeIntervalSince(date) < Self.geoCacheLifetime {
                    return previous
                }
                var result = base
                result.queriedAddress = ip
                if let info = await PublicAddressLookup.geo(for: ip) {
                    result.apply(info)
                    // 分流代理下 cleanip.io 看到的出口可能与 Cloudflare 不同：纯净度是那个地址的，界面也显示那个地址
                    if let seen = info.ip, seen != ip {
                        if family == .v4 { result.ipv4 = seen } else { result.ipv6 = seen }
                    }
                }
                // 这次没查到，地址又没变，先继续用旧的
                if !result.hasLookupData, sameAddress, let previous, previous.hasLookupData { return previous }
                return result
            }

            async let v4 = resolve(.v4, ip: base.ipv4)
            async let v6 = resolve(.v6, ip: base.ipv6)
            var results: [IPFamily: PublicAddresses] = [:]
            if let v4 = await v4 { results[.v4] = v4 }
            if let v6 = await v6 { results[.v6] = v6 }
            // 两份结果都带着两族地址，各族以自己那份结果为准；缓存里留下的另一族旧地址不算
            let ipv4 = results[.v4]?.ipv4 ?? base.ipv4
            let ipv6 = results[.v6]?.ipv6 ?? base.ipv6
            for family in Array(results.keys) {
                results[family]?.ipv4 = ipv4
                results[family]?.ipv6 = ipv6
            }

            // 只留这次还有结果的那几族的时间
            var dates = (cached?.geoDates ?? [:]).filter { key, _ in IPFamily(rawValue: key).map { results[$0] != nil } ?? false }
            for (family, result) in results {
                // 没查到的不记时间，下次打开详情就会重查，而不是空着等 7 天
                guard result.hasLookupData else {
                    dates[family.rawValue] = nil
                    continue
                }
                let previous = cached?.results[family.rawValue]
                let sameAsCached = previous?.asn == result.asn && previous?.purity == result.purity && previous?.city == result.city
                if force || !sameAsCached || dates[family.rawValue] == nil { dates[family.rawValue] = now }
            }
            Self.saveCache(PublicCache(results: Dictionary(uniqueKeysWithValues: results.map { ($0.key.rawValue, $0.value) }),
                                       geoDates: dates))
            publicResults = results
            if publicResults[publicFamily] == nil, let only = publicResults.keys.first { publicFamily = only }
            lastPublicLookup = (Date(), localIPv4)
            isLookingUpPublic = false
        }
    }

    private static func loadCache() -> PublicCache? {
        UserDefaults.standard.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(PublicCache.self, from: $0) }
    }

    private static func saveCache(_ cache: PublicCache) {
        UserDefaults.standard.set(try? JSONEncoder().encode(cache), forKey: cacheKey)
    }

    /// 10 分钟内且本地地址未变化时沿用上次结果
    private func lookUpPublicAddressesIfStale() {
        guard settings.publicIPLookup else { return }
        let localIPv4 = details?.physical?.ipv4 ?? []
        if let last = lastPublicLookup, Date().timeIntervalSince(last.date) < 600, last.localIPv4 == localIPv4 { return }
        lookUpPublicAddresses()
    }

    func clearPublicAddresses() {
        publicResults = [:]
        lastPublicLookup = nil
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    // MARK: 探测

    private func startProbing() {
        let foreground = probingForeground ?? true
        probeTask = Task { [weak self] in
            var sequence: UInt16 = 0
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { return }
                let interval = Double(foreground ? Self.foregroundProbeSeconds : Self.backgroundProbeSeconds)
                if self.details == nil { await self.refreshDetails() }
                let started = clock.now
                guard let address = self.probeAddress else {
                    try? await Task.sleep(for: .seconds(interval))
                    continue
                }
                sequence &+= 1
                let current = sequence
                let latency = await Task.detached {
                    ConnectivityProbe.ping(address, sequence: current, timeout: min(interval, 1.5))
                }.value
                guard !Task.isCancelled else { return }
                self.probes.append(ProbeSample(latency: latency))
                // 后台探测允许系统合并唤醒，更省电
                try? await Task.sleep(until: started + .seconds(interval),
                                      tolerance: foreground ? .milliseconds(100) : .seconds(2), clock: clock)
            }
        }
    }

    // MARK: 截图

    /// 截图时换成文档示例地址，不暴露本机的 IP 与硬件地址
    func maskForSnapshot() {
        guard var details else { return }
        details.physical?.ipv4 = ["192.168.1.20"]
        details.physical?.ipv6 = ["2001:db8::20"]
        details.physical?.router = "192.168.1.1"
        details.physical?.hardwareAddress = "a4:83:e7:12:34:56"
        details.dnsServers = details.physical?.manualDNS.isEmpty == false ? details.physical!.manualDNS : ["192.168.1.1"]
        self.details = details
        var sample = PublicAddresses(ipv4: "203.0.113.24", ipv6: nil, countryCode: "CN",
                                     city: "上海", region: "上海", asn: "AS64500", organization: "EXAMPLE NETWORK")
        sample.cityEnglish = "Shanghai"
        sample.networkType = "Residential"
        sample.connectionType = "Cable/DSL"
        sample.ipType = "Residential IP"
        sample.isNative = true
        sample.residentialProbability = 96
        sample.purity = PublicAddresses.Purity(score: 94, grade: "A", confidence: 100)
        sample.risk = PublicAddresses.Risk(score: 4, label: "Very Clean")
        publicResults = [.v4: sample]
    }
}

extension NetworkController {
    /// 用最近十几秒的平均流量给进程排序：刚安静下来的进程还会在榜上停留一会儿，列表不会忽隐忽现
    func rankedProcesses(_ usage: [NetworkProcessUsage]) -> [NetworkProcessUsage] {
        var current: [String: Double] = [:]
        var byID: [String: NetworkProcessUsage] = [:]
        for process in usage {
            let key = "\(process.pid)"
            current[key] = process.download + process.upload
            byID[key] = process
        }
        processRanking.update(current)
        return processRanking.ranked(limit: 5).compactMap { byID[$0.id] }
    }
}

extension PublicAddresses {
    /// cleanip.io 这次查到了东西（归属地、ASN 或纯净度之一）
    var hasLookupData: Bool { asn != nil || city != nil || purity != nil }
}

/// 公网地址的地址族
public enum IPFamily: String, CaseIterable, Identifiable, Sendable, Codable {
    case v4, v6

    public var id: String { rawValue }
    public var title: String { self == .v4 ? "IPv4" : "IPv6" }
}
