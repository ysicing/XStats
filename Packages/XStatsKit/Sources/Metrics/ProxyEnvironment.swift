import CFNetwork
import Darwin
import Foundation

/// 本机的代理环境：VPN / 增强模式隧道、系统代理、DNS 是否被代理接管、正在运行的代理软件。
/// 只读系统配置，不发任何请求
public struct ProxyEnvironment: Sendable, Codable, Equatable {
    public struct Proxy: Sendable, Codable, Equatable {
        public enum Kind: String, Sendable, Codable { case http, https, socks }
        public var kind: Kind
        public var host: String
        public var port: Int
    }

    /// 默认路由所在隧道的服务名（例如 Surge）与接口（utun6）
    public var tunnelName: String?
    public var tunnelInterface: String?
    public var proxies: [Proxy]
    /// 自动代理配置（PAC）地址
    public var pacURL: String?
    public var dnsServers: [String]
    /// 承载流量的物理网卡，绕开代理时绑定它
    public var physicalInterface: String?
    public var physicalName: String?
    public var localIPv4: [String]
    /// 正在运行的代理 / VPN 软件
    public var apps: [String]

    public init(tunnelName: String? = nil, tunnelInterface: String? = nil, proxies: [Proxy] = [], pacURL: String? = nil,
                dnsServers: [String] = [], physicalInterface: String? = nil, physicalName: String? = nil,
                localIPv4: [String] = [], apps: [String] = []) {
        self.tunnelName = tunnelName
        self.tunnelInterface = tunnelInterface
        self.proxies = proxies
        self.pacURL = pacURL
        self.dnsServers = dnsServers
        self.physicalInterface = physicalInterface
        self.physicalName = physicalName
        self.localIPv4 = localIPv4
        self.apps = apps
    }

    /// 配置了任何一种代理：隧道、系统代理或 PAC
    public var hasProxy: Bool { tunnelInterface != nil || !proxies.isEmpty || pacURL != nil }

    /// DNS 指向 198.18.0.0/15：Surge、Clash 等的 fake-ip，域名解析由代理接管
    public var usesFakeIPDNS: Bool { dnsServers.contains(where: Self.isFakeIP) }

    /// 网络环境的指纹：隧道、代理、网卡或本地地址变了，之前的检测结果就不再代表当前网络
    public var signature: String {
        [tunnelInterface ?? "", proxies.map { "\($0.kind.rawValue)\($0.host):\($0.port)" }.joined(separator: ","),
         pacURL ?? "", physicalInterface ?? "", localIPv4.joined(separator: ","), dnsServers.joined(separator: ",")]
            .joined(separator: "|")
    }

    static func isFakeIP(_ address: String) -> Bool {
        var v4 = in_addr()
        guard inet_pton(AF_INET, address, &v4) == 1 else { return false }
        let value = UInt32(bigEndian: v4.s_addr)
        return value >> 17 == (198 << 24 | 18 << 16) >> 17
    }
}

public enum ProxyEnvironmentReader {
    /// 按应用名识别的常见代理与 VPN 软件
    static let knownApps = [
        "Surge", "ClashX", "ClashX Pro", "ClashX Meta", "Clash Verge", "Clash Nyanpasu", "Mihomo Party", "FlClash",
        "Stash", "Shadowrocket", "Quantumult X", "Loon", "sing-box", "SFM", "Hiddify", "V2rayU", "V2RayXS", "NekoRay",
        "Tailscale", "WireGuard", "Cloudflare WARP", "Mullvad VPN", "NordVPN", "ExpressVPN", "Proton VPN", "Surfshark",
        "Astrill", "Outline", "Tunnelblick", "Viscosity", "OpenVPN Connect", "GlobalProtect", "Cisco Secure Client",
        "FortiClient", "Zscaler",
    ]

    /// `runningAppNames` 由界面层从 NSWorkspace 取，这里不依赖 AppKit
    public static func read(details: NetworkDetails, runningAppNames: [String]) -> ProxyEnvironment {
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        let (proxies, pac) = parseProxies(settings)
        return ProxyEnvironment(tunnelName: details.tunnel?.name, tunnelInterface: details.tunnel?.bsdName,
                                proxies: proxies, pacURL: pac, dnsServers: details.dnsServers,
                                physicalInterface: details.physical?.bsdName, physicalName: details.physical?.displayName,
                                localIPv4: details.physical?.ipv4 ?? [], apps: proxyApps(in: runningAppNames))
    }

    static func parseProxies(_ settings: [String: Any]) -> ([ProxyEnvironment.Proxy], pac: String?) {
        func enabled(_ key: String) -> Bool { (settings[key] as? NSNumber)?.boolValue == true }
        var proxies: [ProxyEnvironment.Proxy] = []
        for (kind, prefix) in [(ProxyEnvironment.Proxy.Kind.http, "HTTP"), (.https, "HTTPS"), (.socks, "SOCKS")] {
            guard enabled("\(prefix)Enable"), let host = settings["\(prefix)Proxy"] as? String, !host.isEmpty else { continue }
            let port = (settings["\(prefix)Port"] as? NSNumber)?.intValue ?? 0
            proxies.append(.init(kind: kind, host: host, port: port))
        }
        let pac = enabled("ProxyAutoConfigEnable") ? (settings["ProxyAutoConfigURLString"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
        return (proxies, pac)
    }

    static func proxyApps(in names: [String]) -> [String] {
        var found: [String] = []
        for name in names where knownApps.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) && !found.contains(name) {
            found.append(name)
        }
        return found
    }
}
