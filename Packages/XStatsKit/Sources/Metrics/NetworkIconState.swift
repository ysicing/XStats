// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreWLAN
import Foundation
import Network
import SystemConfiguration

/// 菜单栏只消费连接状态，不读取流量内容、不扫描附近网络，也不发起互联网探测。
public enum NetworkIconState: Equatable, Sendable {
  case unknown
  case wifi(bars: Int)
  case unassociated, off, unavailable, noInternet
  case ethernet, hotspot, temporary, sharing

  public var isError: Bool {
    switch self {
    case .unassociated, .off, .unavailable, .noInternet: true
    default: false
    }
  }

  public static let samples: [Self] = [
    .unknown, .wifi(bars: 1), .wifi(bars: 2), .wifi(bars: 3), .unassociated,
    .off, .unavailable, .noInternet, .ethernet, .hotspot, .temporary, .sharing,
  ]

  static func read(path: NetworkIconPathMonitor.State? = nil) -> Self {
    let details = NetworkDetailsReader.read()
    let wifi = CWWiFiClient.shared().interface()
    let mode = wifi?.interfaceMode()
    if let store = SCDynamicStoreCreate(nil, "XStats.Connection" as CFString, nil, nil),
      let nat = SCDynamicStoreCopyValue(store, "com.apple.nat" as CFString) as? [String: Any],
      let settings = nat["NAT"] as? [String: Any], settings["Enabled"] as? Bool == true
    {
      return .sharing
    }
    if mode == .hostAP { return .sharing }
    if mode == .IBSS { return .temporary }
    if let physical = details.physical, physical.isUp {
      if path?.satisfied == false { return .noInternet }
      if physical.bsdName == wifi?.interfaceName || physical.wifi != nil {
        if let path, path.wifi && path.expensive && path.satisfied { return .hotspot }
        let bars = physical.wifi?.rssi.map { $0 >= -60 ? 3 : $0 >= -75 ? 2 : 1 } ?? 3
        return .wifi(bars: bars)
      }
      return .ethernet
    }
    guard let wifi else { return .unavailable }
    guard wifi.powerOn() else { return .off }
    // 没有默认路由而无线仍已关联时，不能画成正常联网；此判断不宣称远端服务可达。
    return mode == .station && wifi.wlanChannel() != nil ? .noInternet : .unassociated
  }
}

/// 仅在三合一网络来源需要时监听路由事件；不发请求，关闭、锁屏与停止时释放。
final class NetworkIconPathMonitor: @unchecked Sendable {
  struct State: Sendable {
    let satisfied: Bool
    let wifi: Bool
    let expensive: Bool
  }
  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var state: State?

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let value = State(
        satisfied: path.status == .satisfied,
        wifi: path.usesInterfaceType(.wifi), expensive: path.isExpensive)
      lock.lock()
      state = value
      lock.unlock()
    }
    monitor.start(queue: DispatchQueue(label: "work.12306.xstats.connection", qos: .utility))
  }

  func snapshot() -> State? {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  deinit { monitor.cancel() }
}
