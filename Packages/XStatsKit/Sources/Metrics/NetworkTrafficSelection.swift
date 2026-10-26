// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import SystemConfiguration

extension NetworkSampler {
  /// 复用已有采样周期读取路由状态，不增加定时器或调用完整网络详情读取器。
  static func automaticInterface(counters: [Counter]) -> String? {
    guard let store = SCDynamicStoreCreate(nil, "XStats.Traffic" as CFString, nil, nil),
      let state = SCDynamicStoreCopyMultiple(
        store,
        [
          "State:/Network/Global/IPv4", "State:/Network/Global/IPv6",
          "Setup:/Network/Global/IPv4",
        ] as CFArray,
        ["State:/Network/Service/.*/IPv[46]", "Setup:/Network/Service/.*/Interface"] as CFArray
      ) as? [String: [String: Any]]
    else { return nil }
    return automaticInterface(counters: counters, state: state)
  }

  static func automaticInterface(counters: [Counter], state: [String: [String: Any]]) -> String? {
    let excluded = [
      "utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "wg",
      "lo", "awdl", "llw", "bridge", "vmenet",
    ]
    let available = Set(
      counters.filter { counter in
        counter.flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING)
          && counter.flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0
          && !excluded.contains(where: { counter.name.hasPrefix($0) })
      }.map(\.name))
    for family in ["IPv4", "IPv6"] {
      if let primary = state["State:/Network/Global/\(family)"]?["PrimaryInterface"] as? String,
        available.contains(primary)
      {
        return primary
      }
    }
    // VPN 接管主路由时，按系统服务优先级找承载它的物理网络。
    // 同时支持只有 IPv6 的网络，不回退为所有接口之和。
    let order = state["Setup:/Network/Global/IPv4"]?["ServiceOrder"] as? [String] ?? []
    for id in order {
      let type = state["Setup:/Network/Service/\(id)/Interface"]?["Type"] as? String
      guard type == "Ethernet" || type == "IEEE80211" else { continue }
      for family in ["IPv4", "IPv6"] {
        guard let service = state["State:/Network/Service/\(id)/\(family)"],
          service["Router"] != nil,
          let name = service["InterfaceName"] as? String, available.contains(name)
        else { continue }
        return name
      }
    }
    return nil
  }
}
