// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Localization
import Network

/// 出口检测的一个目标：CleanIP 的国内回显、Cloudflare，或一个常用网站。
/// 做法参照 cleanip.io/outbound：回显端点直接返回它看到的来源 IP；接入 Cloudflare 的网站读 /cdn-cgi/trace，
/// 能实测访问它时的出口、节点与国家；其余网站只能测连通与延迟，出口按规则推断
public struct EgressTarget: Sendable, Hashable, Identifiable {
    public enum Region: String, Sendable, Codable { case domestic, international }

    public enum Category: String, Sendable, CaseIterable {
        case ai, media, social, developer, common, domestic
    }

    enum Probe: Sendable, Hashable {
        /// Cloudflare 的 /cdn-cgi/trace
        case trace
        /// 回显 JSON：{"ip": "…"}
        case echo(path: String)
        /// 只测连通与延迟：请求一个很小的资源，收到任何 HTTP 响应都算通
        case reach(path: String, head: Bool)
    }

    public let id: String
    public let name: String
    public let host: String
    public let category: Category
    /// Resources/Logos 里的图标名
    public let logo: String?
    let probe: Probe

    public var region: Region { category == .domestic || id == Self.domestic.id ? .domestic : .international }

    /// 能读出这次连接的出口；否则只知道通不通
    public var measuresExit: Bool {
        if case .reach = probe { return false }
        return true
    }

    var isIPv6Literal: Bool { host.contains(":") }

    var url: URL {
        let path = switch probe {
        case .trace: "/cdn-cgi/trace"
        case .echo(let path), .reach(let path, _): path
        }
        return URL(string: "https://\(isIPv6Literal ? "[\(host)]" : host)\(path)")!
    }

    /// CleanIP 的国内回显机，用 IP 访问：代理规则里的 GEOIP,CN 能命中它，按域名分流的用户也会直连
    public static let domestic = EgressTarget(id: "domestic", name: "CleanIP", host: "124.222.230.137",
                                              category: .common, logo: nil, probe: .echo(path: "/"))
    /// 用 IP 访问，不经过 DNS，也就不受 fake-ip 与域名规则影响
    public static let cloudflare = EgressTarget(id: "cloudflare", name: "Cloudflare", host: "1.1.1.1",
                                                category: .common, logo: nil, probe: .trace)
    public static let cloudflareIPv6 = EgressTarget(id: "cloudflare-ipv6", name: "Cloudflare", host: "2606:4700:4700::1111",
                                                    category: .common, logo: nil, probe: .trace)

    /// 三条路线都要测的基准目标
    public static let baseline = [domestic, cloudflare, cloudflareIPv6]

    /// 精选网站，只按系统代理测。能读 trace 的优先用 trace（实测出口）
    public static let sites: [EgressTarget] = [
        trace("chatgpt.com", "ChatGPT", .ai, "openai"),
        trace("claude.ai", "Claude", .ai, "claude"),
        reach("gemini.google.com", "Gemini", .ai, "gemini"),
        trace("grok.com", "Grok", .ai, "grok"),
        trace("www.perplexity.ai", "Perplexity", .ai, "perplexity"),
        trace("www.midjourney.com", "Midjourney", .ai, "midjourney"),
        reach("www.youtube.com", "YouTube", .media, "youtube", path: "/generate_204", head: false),
        reach("www.netflix.com", "Netflix", .media, "netflix"),
        reach("www.tiktok.com", "TikTok", .media, "tiktok"),
        reach("www.twitch.tv", "Twitch", .media, "twitch"),
        trace("x.com", "X", .social, "x"),
        reach("telegram.org", "Telegram", .social, "telegram"),
        reach("www.instagram.com", "Instagram", .social, "instagram"),
        reach("discord.com", "Discord", .social, "discord"),
        reach("www.reddit.com", "Reddit", .social, "reddit"),
        reach("github.com", "GitHub", .developer, "github"),
        trace("www.npmjs.com", "npm", .developer, "npm"),
        trace("hub.docker.com", "Docker Hub", .developer, "docker"),
        reach("www.google.com", "Google", .common, "google", path: "/generate_204", head: false),
        trace("www.cloudflare.com", "Cloudflare", .common, "cloudflare"),
        reach("www.baidu.com", tr("百度"), .domestic, "baidu"),
        reach("www.taobao.com", tr("淘宝"), .domestic, "taobao"),
        reach("www.bilibili.com", tr("哔哩哔哩"), .domestic, "bilibili"),
        reach("www.douyin.com", tr("抖音"), .domestic, "douyin"),
        reach("weixin.qq.com", tr("微信"), .domestic, "wechat"),
    ]

    public static let all = baseline + sites

    private static func trace(_ host: String, _ name: String, _ category: Category, _ logo: String) -> EgressTarget {
        EgressTarget(id: host, name: name, host: host, category: category, logo: "site-" + logo, probe: .trace)
    }

    /// 默认用 HEAD 请求 favicon：响应小、不跳转到大页面
    private static func reach(_ host: String, _ name: String, _ category: Category, _ logo: String,
                              path: String = "/favicon.ico", head: Bool = true) -> EgressTarget {
        EgressTarget(id: host, name: name, host: host, category: category, logo: "site-" + logo, probe: .reach(path: path, head: head))
    }
}

/// 请求怎么发出去
public enum EgressRoute: String, Sendable, Codable, CaseIterable {
    /// 按系统代理设置发出（URLSession），浏览器等大多数应用都是这样
    case system
    /// 不读代理设置，直接建连接，走系统路由表；VPN 或增强模式会接管它
    case socket
    /// 绑定物理网卡并忽略代理，绕开 VPN 与代理，得到本机网络原本的出口
    case interface
}

/// 一次测量：某个目标经某条路线看到的出口
public struct EgressHit: Sendable, Codable, Equatable {
    public var targetID: String
    public var route: EgressRoute
    public var ip: String?
    /// Cloudflare 给出的出口国家
    public var country: String?
    /// Cloudflare 接入节点（机场代码）
    public var colo: String?
    public var milliseconds: Int?

    public init(targetID: String, route: EgressRoute, ip: String? = nil, country: String? = nil, colo: String? = nil,
                milliseconds: Int? = nil) {
        self.targetID = targetID
        self.route = route
        self.ip = ip
        self.country = country
        self.colo = colo
        self.milliseconds = milliseconds
    }
}

/// 出口 IP 的归属地与类型，来自 cleanip.io
public struct EgressGeo: Sendable, Codable, Equatable {
    public var countryCode: String?
    public var region: String?
    public var city: String?
    public var regionEnglish: String?
    public var cityEnglish: String?
    public var asn: String?
    public var organization: String?
    public var ipType: String?
    public var isNative: Bool?

    init(_ info: PublicAddressLookup.GeoInfo) {
        countryCode = info.countryCode
        region = info.region
        city = info.city
        regionEnglish = info.regionEnglish
        cityEnglish = info.cityEnglish
        asn = info.asn
        organization = info.organization
        ipType = info.ipType
        isNative = info.isNative
    }
}

public enum EgressProber {
    static let timeout: TimeInterval = 5
    /// 同时进行的请求数：太多会把慢线路上的正常站点挤成超时
    static let concurrency = 10

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "XStats"]
        return URLSession(configuration: configuration)
    }()

    /// 所有要做的测量：基准目标三条路线各一次在前（结论靠它们），精选网站只按系统代理测
    public static var jobCount: Int { EgressTarget.baseline.count * 3 + EgressTarget.sites.count }

    /// `progress` 每完成一项回调一次（已完成数）
    public static func measure(interfaceName: String?, progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> [EgressHit] {
        let interface = await physicalInterface(named: interfaceName)
        var jobs: [(EgressTarget, EgressRoute)] = []
        for target in EgressTarget.baseline {
            jobs.append((target, .system))
            jobs.append((target, .socket))
            jobs.append((target, .interface))
        }
        jobs += EgressTarget.sites.map { ($0, .system) }

        return await withTaskGroup(of: (Int, EgressHit).self) { group in
            var results = [EgressHit?](repeating: nil, count: jobs.count)
            var next = 0
            var done = 0
            while next < min(concurrency, jobs.count) {
                let (index, job) = (next, jobs[next])
                group.addTask { (index, await measure(job.0, route: job.1, interface: interface)) }
                next += 1
            }
            for await (index, hit) in group {
                results[index] = hit
                done += 1
                progress(done)
                if next < jobs.count {
                    let (index, job) = (next, jobs[next])
                    group.addTask { (index, await measure(job.0, route: job.1, interface: interface)) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    /// 系统代理路线先预热一次（建连、握手、代理选路），再计时请求一次，延迟更接近真实往返；
    /// 另外两条路线只用于读出口，请求一次即可
    static func measure(_ target: EgressTarget, route: EgressRoute, interface: NWInterface?) async -> EgressHit {
        var hit = EgressHit(targetID: target.id, route: route)
        if route == .interface && interface == nil { return hit }
        let clock = ContinuousClock()
        var start = clock.now
        guard var response = await fetch(target, route: route, interface: interface) else { return hit }
        if route == .system {
            start = clock.now
            if let timed = await fetch(target, route: route, interface: interface) { response = timed }
        }
        let elapsed = clock.now - start
        hit.milliseconds = Int((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded())

        switch target.probe {
        case .trace:
            let fields = PublicAddressLookup.parseTrace(String(decoding: response, as: UTF8.self))
            hit.ip = fields["ip"]
            hit.country = fields["loc"].flatMap(PublicAddressLookup.validCountryCode)
            hit.colo = fields["colo"].flatMap { $0.isEmpty ? nil : $0 }
        case .echo:
            let ip = (try? JSONDecoder().decode([String: String].self, from: response))?["ip"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            hit.ip = ip.flatMap { PublicAddressLookup.isAddress($0) ? $0 : nil }
        case .reach:
            break
        }
        // 基准目标就是用来读出口的，没读到地址（比如被拦截页顶替）就算没连上；网站只要有响应就算通
        if EgressTarget.baseline.contains(target) && hit.ip == nil { hit.milliseconds = nil }
        return hit
    }

    /// 连上了返回响应体（HEAD 为空数据）；读出口的目标要求 200，只测连通的收到任何 HTTP 响应都算
    private static func fetch(_ target: EgressTarget, route: EgressRoute, interface: NWInterface?) async -> Data? {
        switch route {
        case .system:
            var request = URLRequest(url: target.url)
            if case .reach(_, let head) = target.probe, head { request.httpMethod = "HEAD" }
            guard let (data, response) = try? await session.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
            return target.measuresExit ? (status == 200 ? data : nil) : data
        case .socket:
            return ok(await AddressFamilyRequest.get(target.url, ipv6: target.isIPv6Literal, timeout: timeout,
                                                     options: .init(bypassProxies: true)))
        case .interface:
            guard let interface else { return nil }
            return ok(await AddressFamilyRequest.get(target.url, ipv6: target.isIPv6Literal, timeout: timeout,
                                                     options: .init(interface: interface, bypassProxies: true)))
        }
    }

    // MARK: 归属地

    /// 查某条路线出口的归属地。cleanip.io 只查请求方自己，所以请求必须沿这条路线发出：
    /// 系统代理路线直接请求；网卡路线先经同一块网卡向 Cloudflare DoH 解析 cleanip.io，再连解析到的 IP，
    /// 避免拿到代理下发的 fake-ip。返回 cleanip.io 看到的地址与结果
    public static func geo(route: EgressRoute, ipv6: Bool, interfaceName: String?) async -> (ip: String, geo: EgressGeo)? {
        let url = PublicAddressLookup.cleanIPURL
        let body: Data?
        switch route {
        case .system:
            body = await get(url)
        case .socket:
            body = ok(await AddressFamilyRequest.get(url, ipv6: ipv6, timeout: timeout, options: .init(bypassProxies: true)))
        case .interface:
            guard let interface = await physicalInterface(named: interfaceName),
                  let address = await resolve("cleanip.io", ipv6: ipv6, interface: interface) else { return nil }
            body = ok(await AddressFamilyRequest.get(url, ipv6: ipv6, timeout: timeout,
                                                  options: .init(interface: interface, address: address, bypassProxies: true)))
        }
        guard let body, let info = PublicAddressLookup.parseCleanIP(body), let ip = info.ip else { return nil }
        return (ip, EgressGeo(info))
    }

    /// 经指定网卡用 DoH（JSON 格式）解析域名。某些线路上连不上 Cloudflare，依次换 Google、阿里
    static func resolve(_ name: String, ipv6: Bool, interface: NWInterface) async -> String? {
        let servers = ipv6
            ? ["[2606:4700:4700::1111]/dns-query", "[2001:4860:4860::8888]/resolve", "[2400:3200::1]/resolve"]
            : ["1.1.1.1/dns-query", "8.8.8.8/resolve", "223.5.5.5/resolve"]
        for server in servers {
            guard let url = URL(string: "https://\(server)?name=\(name)&type=\(ipv6 ? 28 : 1)") else { continue }
            if let body = ok(await AddressFamilyRequest.get(url, ipv6: ipv6, timeout: timeout,
                                                          options: .init(interface: interface, bypassProxies: true,
                                                                         accept: "application/dns-json"))),
               let address = parseDoH(body, ipv6: ipv6) {
                return address
            }
        }
        return nil
    }

    static func parseDoH(_ body: Data, ipv6: Bool) -> String? {
        struct Response: Decodable {
            struct Answer: Decodable {
                let type: Int
                let data: String
            }
            let Answer: [Answer]?
        }
        let type = ipv6 ? 28 : 1
        return (try? JSONDecoder().decode(Response.self, from: body))?.Answer?
            .first { $0.type == type && PublicAddressLookup.isAddress($0.data) }?.data
    }

    // MARK: 工具

    private static func get(_ url: URL) async -> Data? {
        ok(await PublicAddressLookup.getWithStatus(url, session: session))
    }

    /// 按接口名找到 Network.framework 的网卡对象；VPN 开着时它仍在可用接口里
    static func physicalInterface(named name: String?) async -> NWInterface? {
        let interfaces = await withCheckedContinuation { (continuation: CheckedContinuation<[NWInterface], Never>) in
            let monitor = NWPathMonitor()
            let resumed = ResumeOnce()
            monitor.pathUpdateHandler = { path in
                guard resumed.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.availableInterfaces)
            }
            monitor.start(queue: DispatchQueue(label: "XStats.EgressProber.interfaces"))
        }
        if let name, let match = interfaces.first(where: { $0.name == name }) { return match }
        return interfaces.first { $0.type == .wifi || $0.type == .wiredEthernet }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

/// 只要 200 的响应体
private func ok(_ response: (Data?, Int)) -> Data? {
    response.1 == 200 ? response.0 : nil
}
