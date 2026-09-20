import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

public struct WiFiLink: Sendable, Equatable {
    /// macOS 14 起读取网络名需要定位权限，未授权时为 nil
    public var ssid: String?
    public var rssi: Int
    public var noise: Int
    public var transmitRate: Double
}

/// 实际承载流量的物理网卡（Wi-Fi、有线网卡等）
public struct PhysicalInterface: Sendable, Equatable {
    public var bsdName: String
    public var displayName: String
    public var serviceID: String
    /// “网络”设置里的服务名，修改 DNS 时使用
    public var serviceName: String
    public var hardwareAddress: String?
    public var isUp: Bool
    public var ipv4: [String]
    public var ipv6: [String]
    public var router: String?
    /// 在该服务上手动设置的 DNS；为空表示使用 DHCP / 路由器下发的地址
    public var manualDNS: [String]
    public var wifi: WiFiLink?
}

/// 默认路由走 VPN / 代理隧道时的服务名与接口（例如 Surge、utun6）
public struct TunnelInterface: Sendable, Equatable {
    public var name: String
    public var bsdName: String
}

public struct NetworkDetails: Sendable, Equatable {
    public var physical: PhysicalInterface?
    public var tunnel: TunnelInterface?
    /// 系统当前实际使用的 DNS 服务器
    public var dnsServers: [String]
}

public enum NetworkDetailsReader {
    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

    static func isTunnel(_ bsdName: String) -> Bool {
        tunnelPrefixes.contains { bsdName.hasPrefix($0) }
    }

    /// 读取接口、地址与 DNS。只读 SystemConfiguration 与 getifaddrs，不需要权限。
    public static func read() -> NetworkDetails {
        guard let store = SCDynamicStoreCreate(nil, "XStats" as CFString, nil, nil) else {
            return NetworkDetails(physical: nil, tunnel: nil, dnsServers: [])
        }
        let globalIPv4 = value(store, "State:/Network/Global/IPv4")
        let globalIPv6 = value(store, "State:/Network/Global/IPv6")
        let primaryBSD = (globalIPv4?["PrimaryInterface"] ?? globalIPv6?["PrimaryInterface"]) as? String
        let primaryService = (globalIPv4?["PrimaryService"] ?? globalIPv6?["PrimaryService"]) as? String
        let dnsServers = value(store, "State:/Network/Global/DNS")?["ServerAddresses"] as? [String] ?? []

        let preferences = SCPreferencesCreate(nil, "XStats" as CFString, nil)
        let addresses = interfaceAddresses()

        var tunnel: TunnelInterface?
        if let primaryBSD, isTunnel(primaryBSD) {
            tunnel = TunnelInterface(name: primaryService.flatMap { serviceName(preferences, $0) } ?? "VPN", bsdName: primaryBSD)
        }

        let physical = physicalService(store: store, preferences: preferences, primaryBSD: primaryBSD,
                                       primaryService: primaryService)
            .map { service -> PhysicalInterface in
                let ipv4State = value(store, "State:/Network/Service/\(service.id)/IPv4")
                let manualDNS = value(store, "Setup:/Network/Service/\(service.id)/DNS")?["ServerAddresses"] as? [String] ?? []
                return PhysicalInterface(
                    bsdName: service.bsdName,
                    displayName: service.displayName,
                    serviceID: service.id,
                    serviceName: service.name,
                    hardwareAddress: service.hardwareAddress,
                    isUp: addresses[service.bsdName]?.isUp ?? false,
                    ipv4: addresses[service.bsdName]?.ipv4 ?? [],
                    ipv6: addresses[service.bsdName]?.ipv6 ?? [],
                    router: ipv4State?["Router"] as? String,
                    manualDNS: manualDNS,
                    wifi: service.isWiFi ? wifiLink(service.bsdName) : nil)
            }
        return NetworkDetails(physical: physical, tunnel: tunnel, dnsServers: dnsServers)
    }

    // MARK: 服务

    private struct Service {
        let id: String
        let name: String
        let bsdName: String
        let displayName: String
        let hardwareAddress: String?
        let isWiFi: Bool
    }

    /// 默认路由直接走物理网卡时就是它；走隧道时，按“网络”设置里的服务顺序取第一个已联网的物理服务
    private static func physicalService(store: SCDynamicStore, preferences: SCPreferences?,
                                        primaryBSD: String?, primaryService: String?) -> Service? {
        guard let preferences, let set = SCNetworkSetCopyCurrent(preferences) else { return nil }
        let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] ?? []
        let order = SCNetworkSetGetServiceOrder(set) as? [String] ?? []
        let ranked = services.sorted { lhs, rhs in
            let left = (SCNetworkServiceGetServiceID(lhs) as String?).flatMap { order.firstIndex(of: $0) } ?? Int.max
            let right = (SCNetworkServiceGetServiceID(rhs) as String?).flatMap { order.firstIndex(of: $0) } ?? Int.max
            return left < right
        }

        let candidates: [Service] = ranked.compactMap { service in
            guard SCNetworkServiceGetEnabled(service),
                  let interface = SCNetworkServiceGetInterface(service),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let id = SCNetworkServiceGetServiceID(service) as String?,
                  !isTunnel(bsdName) else { return nil }
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            return Service(id: id,
                           name: SCNetworkServiceGetName(service) as String? ?? bsdName,
                           bsdName: bsdName,
                           displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsdName,
                           hardwareAddress: SCNetworkInterfaceGetHardwareAddressString(interface) as String?,
                           isWiFi: type == (kSCNetworkInterfaceTypeIEEE80211 as String))
        }
        if let primaryService, let match = candidates.first(where: { $0.id == primaryService }) { return match }
        if let primaryBSD, let match = candidates.first(where: { $0.bsdName == primaryBSD }) { return match }
        return candidates.first { value(store, "State:/Network/Service/\($0.id)/IPv4") != nil }
            ?? candidates.first { value(store, "State:/Network/Service/\($0.id)/IPv6") != nil }
    }

    private static func serviceName(_ preferences: SCPreferences?, _ id: String) -> String? {
        guard let preferences, let service = SCNetworkServiceCopy(preferences, id as CFString) else { return nil }
        return SCNetworkServiceGetName(service) as String?
    }

    private static func value(_ store: SCDynamicStore, _ key: String) -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    private static func wifiLink(_ bsdName: String) -> WiFiLink? {
        guard let interface = CWWiFiClient.shared().interface(withName: bsdName), interface.powerOn() else { return nil }
        let rssi = interface.rssiValue()
        guard rssi != 0 else { return nil }
        return WiFiLink(ssid: interface.ssid(), rssi: rssi, noise: interface.noiseMeasurement(),
                        transmitRate: interface.transmitRate())
    }

    // MARK: 地址

    private struct Addresses {
        var isUp = false
        var ipv4: [String] = []
        var ipv6: [String] = []
    }

    /// 按接口汇总 IPv4 与 IPv6 地址；IPv6 只保留全局与唯一本地地址，不含 fe80 链路本地地址
    private static func interfaceAddresses() -> [String: Addresses] {
        var result: [String: Addresses] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            var info = result[name] ?? Addresses()
            if entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_RUNNING) != 0 { info.isUp = true }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                if let text = numericHost(address) { info.ipv4.append(text) }
            case AF_INET6:
                if let text = numericHost(address), !text.lowercased().hasPrefix("fe80") {
                    info.ipv6.append(text)
                }
            default:
                break
            }
            result[name] = info
        }
        return result
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        // 去掉 IPv6 的作用域后缀（%en0）
        return String(nullTerminated: host).split(separator: "%").first.map(String.init)
    }
}
