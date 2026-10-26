import Darwin
import Foundation
import Localization
import SystemConfiguration

public struct NetworkSampler {
  struct Counter: Equatable {
    var name: String
    var index: UInt32
    var flags: Int32
    var download: UInt64
    var upload: UInt64
  }
  private var last: (counter: Counter, time: UInt64)?

  private var lastConnectionRead: TimeInterval?
  private var lastConnectionPath: NetworkIconPathMonitor.State?
  private var connection: NetworkIconState?
  private var pathMonitor: NetworkIconPathMonitor?

  public init() {}

  /// `getifaddrs` 中的 `if_data.ifi_ibytes` 只有 32 位，超过 4 GiB 会回绕；
  /// 这里用 NET_RT_IFLIST2 读取 `if_data64`。
  static func counters() -> [Counter]? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var length = 0
    guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: length)
    guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0,
      length <= buffer.count
    else { return nil }
    return buffer.withUnsafeBytes { raw in
      var result: [Counter] = []
      var offset = 0
      // 路由缓冲区还包含较短的地址消息，不能要求每条都有完整 if_msghdr 的大小。
      while offset + 4 <= length {
        let size = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        let type = raw.load(fromByteOffset: offset + 3, as: UInt8.self)
        guard size >= 4, size <= length - offset else { return nil }
        if Int32(type) == RTM_IFINFO2, size >= MemoryLayout<if_msghdr2>.size {
          let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
          var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
          if info.ifm_flags & IFF_LOOPBACK == 0,
            if_indextoname(UInt32(info.ifm_index), &name) != nil
          {
            result.append(
              Counter(
                name: String(
                  decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                index: UInt32(info.ifm_index),
                flags: info.ifm_flags, download: info.ifm_data.ifi_ibytes,
                upload: info.ifm_data.ifi_obytes))
          }
        }
        offset += size
      }
      return result
    }
  }

  /// 只在设置界面打开或手动刷新时枚举，包括可手动指定的隧道接口。
  public static func availableTrafficInterfaces() -> [String] {
    (counters() ?? []).map(\.name).sorted()
  }

  public mutating func sample(includeConnection: Bool = false, interfaceName: String = "")
    -> NetworkRate?
  {
    if includeConnection {
      if pathMonitor == nil { pathMonitor = NetworkIconPathMonitor() }
      sampleConnection(uptime: ProcessInfo.processInfo.systemUptime, path: pathMonitor?.snapshot())
    } else {
      stopConnectionMonitoring()
    }
    guard let counters = Self.counters() else {
      last = nil
      return nil
    }
    let selected =
      interfaceName.isEmpty ? Self.automaticInterface(counters: counters) : interfaceName
    return sample(
      counters: counters, interfaceName: selected, time: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
  }

  /// 只对同一接口连续样本做差；切换、断开、读取失败和计数器复位均重新建立基线。
  mutating func sample(counters: [Counter], interfaceName: String?, time: UInt64) -> NetworkRate {
    guard let current = counters.first(where: { $0.name == interfaceName }),
      current.flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING)
    else {
      last = nil
      return NetworkRate(
        connection: connection, downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
        totalDownloaded: 0, totalUploaded: 0)
    }
    var down = 0.0
    var up = 0.0
    if let last, current.name == last.counter.name, current.index == last.counter.index,
      time > last.time, current.download >= last.counter.download,
      current.upload >= last.counter.upload
    {
      let seconds = Double(time - last.time) / 1_000_000_000
      down = Double(current.download - last.counter.download) / seconds
      up = Double(current.upload - last.counter.upload) / seconds
    }
    last = (current, time)
    return NetworkRate(
      connection: connection, interfaceName: current.name, interfaceIndex: current.index,
      downloadBytesPerSecond: down, uploadBytesPerSecond: up,
      totalDownloaded: current.download, totalUploaded: current.upload)
  }

  /// 首个路径回调及路由变化在下一轮现有采样生效；路径未变时保持四秒节流。
  @discardableResult
  mutating func sampleConnection(
    uptime: TimeInterval, path: NetworkIconPathMonitor.State?,
    read: (NetworkIconPathMonitor.State?) -> NetworkIconState = NetworkIconState.read
  ) -> NetworkIconState {
    if connection == nil || path != lastConnectionPath
      || (lastConnectionRead.map { uptime - $0 >= 4 } ?? true)
    {
      connection = read(path)
      lastConnectionRead = uptime
      lastConnectionPath = path
    }
    return connection ?? .unknown
  }

  mutating func stopConnectionMonitoring() {
    pathMonitor = nil
    connection = nil
    lastConnectionRead = nil
    lastConnectionPath = nil
  }

  public static func primaryInterface(named selectedName: String? = nil) -> NetworkInterfaceInfo? {
    guard let store = SCDynamicStoreCreate(nil, "XStats" as CFString, nil, nil),
      let bsdName = selectedName
        ?? (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
        as? [String: Any])?["PrimaryInterface"] as? String
    else { return nil }

    let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
    let systemName =
      interfaces
      .first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
      .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
    // utun / ipsec / ppp 是 VPN 或代理隧道，系统不提供显示名
    let tunnelPrefixes = ["utun", "ipsec", "ppp"]
    let displayName =
      systemName
      ?? (tunnelPrefixes.contains { bsdName.hasPrefix($0) } ? tr("VPN 隧道") : bsdName)

    let state =
      SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(bsdName)/IPv4" as CFString)
      as? [String: Any]
    let address = (state?["Addresses"] as? [String])?.first
    return NetworkInterfaceInfo(bsdName: bsdName, displayName: displayName, ipv4: address)
  }
}
