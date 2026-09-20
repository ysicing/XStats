import Darwin
import Foundation

/// 把三条路线的测量结果归纳成结论：分流是否生效、各网站从哪个出口出去、IPv6 与系统代理有没有漏洞。
///
/// 关键在“原始出口”：绑定物理网卡、绕开 VPN 与代理测到的地址。某个目标按系统代理访问时的出口
/// 与原始出口相同就是直连，不同就是经过了代理。网页版读不到原始出口，只能拿国内回显去猜
public struct EgressAnalysis: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// 所有目标都连不上
        case offline
        /// 没有配置代理，全部直连
        case noProxy
        /// 配置了代理，但测试的目标都在直连
        case proxyInactive
        /// 国内直连，国际网站全部经代理
        case split
        /// 按规则分流：有的直连、有的经代理，但不是“国内直连、国际代理”这种标准分法
        case mixed
        /// 全部经代理
        case fullProxy
        /// VPN 不让绕开它连接，读不到原始出口，分不清哪个出口是代理
        case unverified
    }

    public enum Path: Sendable, Equatable {
        case direct, proxy, unknown
    }

    /// 一个出口与经它出去的目标
    public struct Exit: Sendable, Equatable, Identifiable {
        public struct Entry: Sendable, Equatable {
            public var targetID: String
            /// 实测：读到了这次连接的出口；否则是按国内 / 国际规则推断的
            public var measured: Bool
        }

        public var ip: String
        public var path: Path
        public var entries: [Entry]
        /// Cloudflare 给出的国家，归属地查不到时用它
        public var country: String?
        public var id: String { ip }
    }

    public enum Finding: Sendable, Equatable {
        /// 隧道接管了 IPv4，IPv6 却没经过它，暴露了这个地址
        case ipv6Leak(String)
        /// 代理开着时 IPv6 连不出去：被拦截了，不会泄露
        case ipv6Blocked
        /// IPv6 也经过代理
        case ipv6Proxied
        /// 只设了系统代理，不读代理设置的程序仍在直连
        case socketBypass
        /// 本机在中国大陆，国内网站却走了代理
        case domesticProxied
    }

    public var verdict: Verdict
    /// 原始出口：绑定物理网卡测到的地址
    public var rawAddresses: [String]
    public var rawCountry: String?
    /// 按系统代理访问各目标时用到的出口，经代理的在前
    public var exits: [Exit]
    /// 按系统代理连不上的目标（IPv6 基准目标不算，没有 IPv6 很常见）
    public var failedTargetIDs: [String]
    /// 连得上，但读不到出口，也没有可参照的出口
    public var unassignedTargetIDs: [String]
    public var findings: [Finding]
    /// 结论依据：实测出口里直连与经代理的数量
    public var directCount: Int
    public var proxyCount: Int

    public func path(of ip: String) -> Path {
        guard !rawAddresses.isEmpty else { return .unknown }
        return rawAddresses.contains { Self.sameExit($0, ip) } ? .direct : .proxy
    }

    public static func hit(_ hits: [EgressHit], _ target: EgressTarget, _ route: EgressRoute) -> EgressHit? {
        hits.first { $0.targetID == target.id && $0.route == route }
    }

    public static func evaluate(_ hits: [EgressHit], environment: ProxyEnvironment) -> EgressAnalysis {
        func ip(_ target: EgressTarget, _ route: EgressRoute) -> String? { hit(hits, target, route)?.ip }

        let raw = [ip(.domestic, .interface), ip(.cloudflare, .interface), ip(.cloudflareIPv6, .interface)].compactMap { $0 }
        let rawCountry = hits.lazy.filter { $0.route == .interface }.compactMap(\.country).first
        var analysis = EgressAnalysis(verdict: .offline, rawAddresses: raw, rawCountry: rawCountry, exits: [],
                                      failedTargetIDs: [], unassignedTargetIDs: [], findings: [],
                                      directCount: 0, proxyCount: 0)
        let system = hits.filter { $0.route == .system }
        let ipv6 = EgressTarget.cloudflareIPv6.id

        var exits: [Exit] = []
        func add(_ address: String, _ entry: Exit.Entry, country: String?) {
            if let index = exits.firstIndex(where: { $0.ip == address }) {
                exits[index].entries.append(entry)
                exits[index].country = exits[index].country ?? country
            } else {
                exits.append(Exit(ip: address, path: analysis.path(of: address), entries: [entry], country: country))
            }
        }
        for hit in system {
            guard let address = hit.ip else { continue }
            add(address, .init(targetID: hit.targetID, measured: true), country: hit.country)
        }
        // 读不到出口的网站：国内的归到国内回显的出口，国外的归到 Cloudflare 的出口（没有就取国外网站最常见的出口）
        let international = ip(.cloudflare, .system) ?? system
            .filter { $0.targetID != EgressTarget.domestic.id && $0.targetID != ipv6 }
            .compactMap(\.ip)
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .max { $0.value < $1.value }?.key
        for hit in system where hit.ip == nil && hit.milliseconds != nil {
            let region = EgressTarget.all.first { $0.id == hit.targetID }?.region
            if let reference = region == .domestic ? ip(.domestic, .system) : international {
                add(reference, .init(targetID: hit.targetID, measured: false), country: nil)
            } else {
                analysis.unassignedTargetIDs.append(hit.targetID)
            }
        }
        // 经代理的在前，其次读不出的，直连最后；同类按目标数从多到少，再按出现顺序
        let rank: (Path) -> Int = { $0 == .proxy ? 0 : $0 == .unknown ? 1 : 2 }
        analysis.exits = exits.enumerated().sorted { lhs, rhs in
            let left = (rank(lhs.element.path), -lhs.element.entries.count, lhs.offset)
            let right = (rank(rhs.element.path), -rhs.element.entries.count, rhs.offset)
            return left < right
        }.map(\.element)
        analysis.failedTargetIDs = system.filter { $0.milliseconds == nil && $0.targetID != ipv6 }.map(\.targetID)

        // 结论只数实测出口（IPv4 基准与接入 Cloudflare 的网站）；IPv6 基准单独在下面判断
        let counted = system.compactMap { hit in hit.targetID == ipv6 ? nil : hit.ip.map { (hit.targetID, analysis.path(of: $0)) } }
        analysis.directCount = counted.filter { $0.1 == .direct }.count
        analysis.proxyCount = counted.filter { $0.1 == .proxy }.count
        let domestic = counted.first { $0.0 == EgressTarget.domestic.id }?.1
        let internationalDirect = counted.contains { $0.0 != EgressTarget.domestic.id && $0.1 == .direct }

        if counted.isEmpty {
            analysis.verdict = .offline
        } else if raw.isEmpty {
            analysis.verdict = .unverified
        } else if analysis.proxyCount == 0 {
            analysis.verdict = environment.hasProxy ? .proxyInactive : .noProxy
        } else if analysis.directCount == 0 {
            analysis.verdict = .fullProxy
        } else if domestic == .direct && !internationalDirect {
            analysis.verdict = .split
        } else {
            analysis.verdict = .mixed
        }

        guard analysis.proxyCount > 0 else { return analysis }
        // 不读代理设置的连接：IPv4 也直连说明只有系统代理，IPv6 泄露就无从谈起；IPv4 被接管了才看 IPv6
        if let socketV4 = ip(.cloudflare, .socket), analysis.path(of: socketV4) == .direct {
            analysis.findings.append(.socketBypass)
        } else if let rawV6 = ip(.cloudflareIPv6, .interface) {
            if let socketV6 = ip(.cloudflareIPv6, .socket) {
                analysis.findings.append(sameExit(socketV6, rawV6) ? .ipv6Leak(socketV6) : .ipv6Proxied)
            } else {
                analysis.findings.append(.ipv6Blocked)
            }
        }
        if rawCountry == "CN", domestic == .proxy, analysis.verdict == .mixed {
            analysis.findings.append(.domesticProxied)
        }
        return analysis
    }

    /// IPv4 比整个地址；IPv6 比前 64 位：同一个网络里，不同连接可能用不同的临时地址
    static func sameExit(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        var left = in6_addr()
        var right = in6_addr()
        guard inet_pton(AF_INET6, lhs, &left) == 1, inet_pton(AF_INET6, rhs, &right) == 1 else { return false }
        return withUnsafeBytes(of: &left) { a in withUnsafeBytes(of: &right) { b in a.prefix(8).elementsEqual(b.prefix(8)) } }
    }
}
