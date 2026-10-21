import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

public struct WiFiLink: Sendable, Equatable {
  /// macOS 14 起读取网络名需要定位权限，未授权时为 nil
  public var ssid: String?
  public var rssi: Int?
  public var noise: Int?
  public var transmitRate: Double?
  public var bssid: String?
  public var bandGHz: Double?
  public var channel: Int?
  public var channelWidthMHz: Int?
  public var phyMode: String?
  public var security: String?

  /// 0 是 CoreWLAN 未提供测量的占位值，不能显示为真实信号或参与信噪比计算。
  public init(
    ssid: String?, rssi: Int?, noise: Int?, transmitRate: Double?,
    bssid: String? = nil, bandGHz: Double? = nil, channel: Int? = nil,
    channelWidthMHz: Int? = nil, phyMode: String? = nil, security: String? = nil
  ) {
    self.ssid = ssid
    self.rssi = rssi.flatMap { $0 < 0 ? $0 : nil }
    self.noise = noise.flatMap { $0 < 0 ? $0 : nil }
    self.transmitRate = transmitRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    self.bssid = bssid
    self.bandGHz = bandGHz
    self.channel = channel
    self.channelWidthMHz = channelWidthMHz
    self.phyMode = phyMode
    self.security = security
  }

  public var signalToNoiseRatio: Int? {
    guard let rssi, let noise, rssi < 0, noise < 0, rssi >= noise else { return nil }
    return rssi - noise
  }
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
    let dnsServers =
      value(store, "State:/Network/Global/DNS")?["ServerAddresses"] as? [String] ?? []

    let preferences = SCPreferencesCreate(nil, "XStats" as CFString, nil)
    let addresses = interfaceAddresses()

    var tunnel: TunnelInterface?
    if let primaryBSD, isTunnel(primaryBSD) {
      tunnel = TunnelInterface(
        name: primaryService.flatMap { serviceName(preferences, $0) } ?? "VPN", bsdName: primaryBSD)
    }

    let physical = physicalService(
      store: store, preferences: preferences, primaryBSD: primaryBSD,
      primaryService: primaryService
    )
    .map { service -> PhysicalInterface in
      let ipv4State = value(store, "State:/Network/Service/\(service.id)/IPv4")
      let manualDNS =
        value(store, "Setup:/Network/Service/\(service.id)/DNS")?["ServerAddresses"] as? [String]
        ?? []
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

  struct ConnectionInterface: Sendable {
    let bsdName: String
    let isUp: Bool
    let isWiFi: Bool
  }

  /// 图标复用详情页的物理服务选择，只读取接口标志和共享状态，不解析地址与 DNS。
  static func readConnection() -> (physical: ConnectionInterface?, sharing: Bool) {
    guard let store = SCDynamicStoreCreate(nil, "XStats.Connection" as CFString, nil, nil) else {
      return (nil, false)
    }
    let nat = value(store, "com.apple.nat")?["NAT"] as? [String: Any]
    if nat?["Enabled"] as? Bool == true { return (nil, true) }
    let ipv4 = value(store, "State:/Network/Global/IPv4")
    let ipv6 = value(store, "State:/Network/Global/IPv6")
    guard
      let service = physicalService(
        store: store, preferences: SCPreferencesCreate(nil, "XStats" as CFString, nil),
        primaryBSD: (ipv4?["PrimaryInterface"] ?? ipv6?["PrimaryInterface"]) as? String,
        primaryService: (ipv4?["PrimaryService"] ?? ipv6?["PrimaryService"]) as? String)
    else { return (nil, false) }

    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return (nil, false) }
    defer { freeifaddrs(head) }
    var isUp = false
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let entry = pointer.pointee
      guard entry.ifa_addr != nil, String(cString: entry.ifa_name) == service.bsdName else {
        continue
      }
      isUp = entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING)
      if isUp { break }
    }
    return (
      ConnectionInterface(bsdName: service.bsdName, isUp: isUp, isWiFi: service.isWiFi), false
    )
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
  private static func physicalService(
    store: SCDynamicStore, preferences: SCPreferences?,
    primaryBSD: String?, primaryService: String?
  ) -> Service? {
    guard let preferences, let set = SCNetworkSetCopyCurrent(preferences) else { return nil }
    let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] ?? []
    let order = SCNetworkSetGetServiceOrder(set) as? [String] ?? []
    let ranked = services.sorted { lhs, rhs in
      let left =
        (SCNetworkServiceGetServiceID(lhs) as String?).flatMap { order.firstIndex(of: $0) }
        ?? Int.max
      let right =
        (SCNetworkServiceGetServiceID(rhs) as String?).flatMap { order.firstIndex(of: $0) }
        ?? Int.max
      return left < right
    }

    let candidates: [Service] = ranked.compactMap { service in
      guard SCNetworkServiceGetEnabled(service),
        let interface = SCNetworkServiceGetInterface(service),
        let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
        let id = SCNetworkServiceGetServiceID(service) as String?,
        !isTunnel(bsdName)
      else { return nil }
      let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
      return Service(
        id: id,
        name: SCNetworkServiceGetName(service) as String? ?? bsdName,
        bsdName: bsdName,
        displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsdName,
        hardwareAddress: SCNetworkInterfaceGetHardwareAddressString(interface) as String?,
        isWiFi: type == (kSCNetworkInterfaceTypeIEEE80211 as String))
    }
    if let primaryService, let match = candidates.first(where: { $0.id == primaryService }) {
      return match
    }
    if let primaryBSD, let match = candidates.first(where: { $0.bsdName == primaryBSD }) {
      return match
    }
    return candidates.first { value(store, "State:/Network/Service/\($0.id)/IPv4") != nil }
      ?? candidates.first { value(store, "State:/Network/Service/\($0.id)/IPv6") != nil }
  }

  private static func serviceName(_ preferences: SCPreferences?, _ id: String) -> String? {
    guard let preferences, let service = SCNetworkServiceCopy(preferences, id as CFString) else {
      return nil
    }
    return SCNetworkServiceGetName(service) as String?
  }

  private static func value(_ store: SCDynamicStore, _ key: String) -> [String: Any]? {
    SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
  }

  private static func wifiLink(_ bsdName: String) -> WiFiLink? {
    guard let interface = CWWiFiClient.shared().interface(withName: bsdName), interface.powerOn(),
      interface.interfaceMode() != .none
    else { return nil }
    let channel = interface.wlanChannel()
    let band: Double? =
      switch channel?.channelBand {
      case .band2GHz: 2.4
      case .band5GHz: 5
      case .band6GHz: 6
      default: nil
      }
    let width: Int? =
      switch channel?.channelWidth {
      case .width20MHz: 20
      case .width40MHz: 40
      case .width80MHz: 80
      case .width160MHz: 160
      default: nil
      }
    let phy: String? =
      switch interface.activePHYMode() {
      case .mode11a: "802.11a"
      case .mode11b: "802.11b"
      case .mode11g: "802.11g"
      case .mode11n: "802.11n"
      case .mode11ac: "802.11ac"
      case .mode11ax: "802.11ax"
      // 枚举名 mode11be 仅在较新的 SDK 中存在，按原始值（kCWPHYMode11be = 7）匹配以兼容旧 SDK 编译。
      case let mode where mode.rawValue == 7: "802.11be"
      default: nil
      }
    let security: String? =
      switch interface.security() {
      case .none: "开放网络"
      case .WEP: "WEP"
      case .wpaPersonal: "WPA Personal"
      case .wpaPersonalMixed: "WPA/WPA2 Personal"
      case .wpa2Personal: "WPA2 Personal"
      case .personal: "Personal"
      case .dynamicWEP: "Dynamic WEP"
      case .wpaEnterprise: "WPA Enterprise"
      case .wpaEnterpriseMixed: "WPA/WPA2 Enterprise"
      case .wpa2Enterprise: "WPA2 Enterprise"
      case .enterprise: "Enterprise"
      case .wpa3Personal: "WPA3 Personal"
      case .wpa3Enterprise: "WPA3 Enterprise"
      case .wpa3Transition: "WPA2/WPA3 Personal"
      case .OWE: "OWE"
      case .oweTransition: "OWE Transition"
      default: nil
      }
    return WiFiLink(
      ssid: interface.ssid(), rssi: interface.rssiValue(), noise: interface.noiseMeasurement(),
      transmitRate: interface.transmitRate(), bssid: interface.bssid(), bandGHz: band,
      channel: channel?.channelNumber, channelWidthMHz: width, phyMode: phy, security: security)
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
      if entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_RUNNING) != 0 {
        info.isUp = true
      }

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
    guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
    else { return nil }
    // 去掉 IPv6 的作用域后缀（%en0）
    return String(nullTerminated: host).split(separator: "%").first.map(String.init)
  }
}
