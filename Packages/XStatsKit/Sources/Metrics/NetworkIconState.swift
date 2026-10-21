// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreWLAN
import Foundation
import Network

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

  init(wifiRSSI: Int?) {
    // 已连接不代表已取得信号测量，缺失读数不能显示成满格。
    guard let wifiRSSI, wifiRSSI < 0 else {
      self = .unknown
      return
    }
    self = .wifi(bars: wifiRSSI >= -60 ? 3 : wifiRSSI >= -75 ? 2 : 1)
  }

  /// 已联网接口的状态优先级；有线和无路由不需要读取信号强度。
  static func connected(
    isWiFi: Bool, path: NetworkIconPathMonitor.State?, rssi: () -> Int?
  ) -> Self {
    if path?.satisfied == false { return .noInternet }
    guard isWiFi else { return .ethernet }
    // 连接成本不能证明是个人热点；无法确认类型时沿用物理 Wi-Fi 的信号状态。
    return Self(wifiRSSI: rssi())
  }

  static func read(path: NetworkIconPathMonitor.State? = nil) -> Self {
    let connection = NetworkDetailsReader.readConnection()
    if connection.sharing { return .sharing }
    let client = CWWiFiClient.shared()
    let wifi = client.interface()
    let mode = wifi?.interfaceMode()
    if mode == .hostAP { return .sharing }
    if mode == .IBSS { return .temporary }
    if let physical = connection.physical, physical.isUp {
      let isDefaultWiFi = physical.bsdName == wifi?.interfaceName
      return connected(isWiFi: physical.isWiFi || isDefaultWiFi, path: path) {
        guard physical.isWiFi else { return nil }
        let interface = isDefaultWiFi ? wifi : client.interface(withName: physical.bsdName)
        guard let interface, interface.powerOn(),
          (isDefaultWiFi ? mode : interface.interfaceMode()) != CWInterfaceMode.none
        else { return nil }
        return interface.rssiValue()
      }
    }
    guard let wifi else { return .unavailable }
    guard wifi.powerOn() else { return .off }
    // 没有默认路由而无线仍已关联时，不能画成正常联网；此判断不宣称远端服务可达。
    return mode == .station && wifi.wlanChannel() != nil ? .noInternet : .unassociated
  }
}

/// 仅在三合一网络来源需要时监听路由事件；不发请求，关闭、锁屏与停止时释放。
final class NetworkIconPathMonitor: @unchecked Sendable {
  struct State: Equatable, Sendable {
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
