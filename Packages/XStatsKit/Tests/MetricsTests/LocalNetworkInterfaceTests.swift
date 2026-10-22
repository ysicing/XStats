// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Metrics

struct LocalNetworkInterfaceTests {
  @Test func includesEveryConnectedInterfaceAndKeepsReliableServiceNames() {
    let addresses: [String: NetworkDetailsReader.Addresses] = [
      "en0": .init(isUp: true, ipv4: ["192.168.1.20"]),
      "en7": .init(isUp: true, ipv4: ["10.0.0.20"]),
      "utun6": .init(isUp: true, ipv4: ["100.80.1.2"], ipv6: ["fd7a:115c:a1e0::1"]),
      "utun9": .init(isUp: true, ipv4: ["10.8.0.2"]),
      "utun10": .init(isUp: true, ipv4: ["100.81.1.2"]),
    ]
    let result = NetworkDetailsReader.localInterfaces(
      addresses: addresses,
      services: [
        "en0": .init(name: "Wi-Fi", kind: .wifi),
        "en7": .init(name: "USB Ethernet", kind: .ethernet),
        "utun6": .init(name: "Tailscale", kind: .tunnel),
        "utun9": .init(name: "WireGuard", kind: .tunnel),
      ], primaryBSD: "en7")
    #expect(result.map(\.id) == ["en7", "en0", "utun6", "utun9", "utun10"])
    #expect(result[2].name == "Tailscale" && result[3].name == "WireGuard")
    // 同一个 CGNAT 地址段不能作为 Tailscale 产品名的识别依据。
    #expect(result[4].name == nil && result[4].kind == .tunnel)
    #expect(result[2].ipv6 == ["fd7a:115c:a1e0::1"])
  }

  @Test func filtersSystemDisconnectedAndAddresslessInterfaces() {
    let result = NetworkDetailsReader.localInterfaces(
      addresses: [
        "lo0": .init(isUp: true, isLoopback: true, ipv4: ["127.0.0.1"], ipv6: ["::1"]),
        "awdl0": .init(isUp: true, ipv4: ["192.168.1.2"]),
        "llw0": .init(isUp: true, ipv6: ["fd00::2"]),
        "en1": .init(isUp: false, ipv4: ["192.168.1.2"]),
        "en2": .init(isUp: true),
        "utun0": .init(isUp: true, ipv6: ["fe80::1"]),
        "utun1": .init(isUp: true, ipv6: ["febf::1"]),
        "en3": .init(isUp: true, ipv4: ["169.254.1.2"]),
        "en4": .init(isUp: true, ipv4: ["0.0.0.0", "224.0.0.1"], ipv6: ["::", "::1", "ff02::1"]),
      ], services: [:], primaryBSD: nil)
    #expect(result.isEmpty)
  }

  @Test func keepsGlobalAndUniqueLocalIPv6AndMovesLinkLocalToDetails() throws {
    let result = NetworkDetailsReader.localInterfaces(
      addresses: [
        "en0": .init(
          isUp: true,
          ipv4: ["192.168.1.2", "192.168.1.2", "169.254.1.2"],
          ipv6: ["2001:db8::2", "fd00::2", "fe80::2", "febf::3", "::1", "ff02::1"])
      ], services: [:], primaryBSD: nil)
    let value = try #require(result.first)
    #expect(value.ipv4 == ["192.168.1.2"])
    #expect(value.ipv6 == ["2001:db8::2", "fd00::2"])
    #expect(value.linkLocal == ["169.254.1.2", "fe80::2%en0", "febf::3%en0"])
  }
}
