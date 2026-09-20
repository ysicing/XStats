import Foundation
import Testing
@testable import Metrics

@Suite("出口与分流判定")
struct EgressAnalysisTests {
    private let raw = "144.124.192.33"
    private let rawV6 = "2a05:45c2:4053:3001:acf9:d8c2:547b:a885"
    private let proxy = "212.135.40.68"
    private let tunnel = ProxyEnvironment(tunnelName: "Surge", tunnelInterface: "utun6")

    /// 原始出口、按系统代理访问国内回显与 Cloudflare、常用网站，各给一个出口；有地址的算连上了
    private func hits(domestic: String?, cloudflare: String?, sites: [String: String?] = [:], reachable: [String] = [],
                      socketV4: String? = nil, socketV6: String? = nil, rawV6: String? = nil,
                      rawV4: String? = "144.124.192.33") -> [EgressHit] {
        var hits = [
            EgressHit(targetID: EgressTarget.domestic.id, route: .interface, ip: rawV4),
            EgressHit(targetID: EgressTarget.cloudflare.id, route: .interface, ip: rawV4, country: rawV4 == nil ? nil : "UZ"),
            EgressHit(targetID: EgressTarget.cloudflareIPv6.id, route: .interface, ip: rawV6),
            EgressHit(targetID: EgressTarget.domestic.id, route: .system, ip: domestic),
            EgressHit(targetID: EgressTarget.cloudflare.id, route: .system, ip: cloudflare),
            EgressHit(targetID: EgressTarget.cloudflareIPv6.id, route: .system),
            EgressHit(targetID: EgressTarget.cloudflare.id, route: .socket, ip: socketV4),
            EgressHit(targetID: EgressTarget.cloudflareIPv6.id, route: .socket, ip: socketV6),
        ]
        for (id, ip) in sites.sorted(by: { $0.key < $1.key }) {
            hits.append(EgressHit(targetID: id, route: .system, ip: ip))
        }
        for id in reachable {
            hits.append(EgressHit(targetID: id, route: .system, milliseconds: 80))
        }
        return hits.map { hit in
            var hit = hit
            if hit.ip != nil { hit.milliseconds = 100 }
            return hit
        }
    }

    @Test func splitWhenDomesticDirectAndInternationalProxied() {
        let result = EgressAnalysis.evaluate(hits(domestic: raw, cloudflare: proxy, sites: ["chatgpt.com": proxy]), environment: tunnel)
        #expect(result.verdict == .split)
        #expect(result.exits.map(\.ip) == [proxy, raw])
        #expect(result.exits.first?.entries.map(\.targetID) == [EgressTarget.cloudflare.id, "chatgpt.com"])
    }

    @Test func fullProxyAndMixed() {
        let full = EgressAnalysis.evaluate(hits(domestic: proxy, cloudflare: proxy), environment: tunnel)
        #expect(full.verdict == .fullProxy)
        // 某个网站被规则放行直连
        let mixed = EgressAnalysis.evaluate(hits(domestic: proxy, cloudflare: proxy, sites: ["claude.ai": raw]), environment: tunnel)
        #expect(mixed.verdict == .mixed)
        #expect(mixed.directCount == 1 && mixed.proxyCount == 2)
    }

    @Test func directOnlyDependsOnProxyConfiguration() {
        #expect(EgressAnalysis.evaluate(hits(domestic: raw, cloudflare: raw), environment: ProxyEnvironment()).verdict == .noProxy)
        #expect(EgressAnalysis.evaluate(hits(domestic: raw, cloudflare: raw), environment: tunnel).verdict == .proxyInactive)
    }

    @Test func offlineAndUnverified() {
        #expect(EgressAnalysis.evaluate(hits(domestic: nil, cloudflare: nil), environment: tunnel).verdict == .offline)
        let blocked = EgressAnalysis.evaluate(hits(domestic: proxy, cloudflare: proxy, rawV4: nil), environment: tunnel)
        #expect(blocked.verdict == .unverified)
        #expect(blocked.exits.allSatisfy { $0.path == .unknown })
    }

    @Test func ipv6Findings() {
        let leak = EgressAnalysis.evaluate(hits(domestic: raw, cloudflare: proxy, socketV4: proxy,
                                                socketV6: "2a05:45c2:4053:3001::1234", rawV6: rawV6), environment: tunnel)
        #expect(leak.findings == [.ipv6Leak("2a05:45c2:4053:3001::1234")])
        let blocked = EgressAnalysis.evaluate(hits(domestic: raw, cloudflare: proxy, socketV4: proxy, rawV6: rawV6), environment: tunnel)
        #expect(blocked.findings == [.ipv6Blocked])
        let proxied = EgressAnalysis.evaluate(hits(domestic: raw, cloudflare: proxy, socketV4: proxy,
                                                   socketV6: "2001:db8::1", rawV6: rawV6), environment: tunnel)
        #expect(proxied.findings == [.ipv6Proxied])
    }

    @Test func systemProxyOnlyLetsOtherProgramsBypass() {
        let result = EgressAnalysis.evaluate(hits(domestic: raw, cloudflare: proxy, socketV4: raw, socketV6: rawV6, rawV6: rawV6),
                                             environment: ProxyEnvironment(proxies: [.init(kind: .http, host: "127.0.0.1", port: 6152)]))
        #expect(result.findings == [.socketBypass])
    }

    @Test func infersExitsForSitesWithoutTrace() {
        // YouTube 读不到出口，归到 Cloudflare 的出口；百度归到国内回显的出口；没连上的 Netflix 单列
        var input = hits(domestic: raw, cloudflare: proxy, reachable: ["www.youtube.com", "www.baidu.com"])
        input.append(EgressHit(targetID: "www.netflix.com", route: .system))
        let result = EgressAnalysis.evaluate(input, environment: tunnel)
        #expect(result.verdict == .split)
        let proxied = result.exits.first { $0.ip == proxy }
        #expect(proxied?.entries.contains(.init(targetID: "www.youtube.com", measured: false)) == true)
        let direct = result.exits.first { $0.ip == raw }
        #expect(direct?.entries.contains(.init(targetID: "www.baidu.com", measured: false)) == true)
        #expect(result.failedTargetIDs == ["www.netflix.com"])
        // 推断的不影响结论的计数
        #expect(result.proxyCount == 1 && result.directCount == 1)
    }

    @Test func sameExitComparesIPv6Prefix() {
        #expect(EgressAnalysis.sameExit("2a05:45c2:4053:3001::1", "2a05:45c2:4053:3001:acf9::2"))
        #expect(!EgressAnalysis.sameExit("2a05:45c2:4053:3002::1", "2a05:45c2:4053:3001::1"))
        #expect(!EgressAnalysis.sameExit("1.2.3.4", "1.2.3.5"))
    }
}

@Suite("代理环境")
struct ProxyEnvironmentTests {
    @Test func parsesSystemProxies() {
        let settings: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 6152,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 6152,
            "SOCKSEnable": 0, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 6153,
            "ProxyAutoConfigEnable": 0,
        ]
        let (proxies, pac) = ProxyEnvironmentReader.parseProxies(settings)
        #expect(proxies.map(\.kind) == [.http, .https])
        #expect(proxies.first?.port == 6152)
        #expect(pac == nil)
    }

    @Test func detectsFakeIPAndApps() {
        #expect(ProxyEnvironment(dnsServers: ["198.18.0.2"]).usesFakeIPDNS)
        #expect(ProxyEnvironment(dnsServers: ["198.19.255.1"]).usesFakeIPDNS)
        #expect(!ProxyEnvironment(dnsServers: ["198.20.0.1", "1.1.1.1"]).usesFakeIPDNS)
        #expect(ProxyEnvironmentReader.proxyApps(in: ["Safari", "Surge", "Clash Verge", "Surgeon"]) == ["Surge", "Clash Verge"])
    }

    @Test func parsesDoHAnswer() {
        let json = #"{"Status":0,"Answer":[{"name":"cleanip.io","type":5,"data":"x.example"},{"name":"cleanip.io","type":1,"data":"104.26.11.201"}]}"#
        #expect(EgressProber.parseDoH(Data(json.utf8), ipv6: false) == "104.26.11.201")
        #expect(EgressProber.parseDoH(Data(json.utf8), ipv6: true) == nil)
    }
}
