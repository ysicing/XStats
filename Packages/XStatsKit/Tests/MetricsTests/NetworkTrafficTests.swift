// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Testing
@testable import Metrics

struct NetworkTrafficTests {
  private func counter(_ name: String, _ bytes: UInt64, index: UInt32 = 1) -> NetworkSampler.Counter
  {
    .init(
      name: name, index: index, flags: IFF_UP | IFF_RUNNING, download: bytes, upload: bytes / 10)
  }

  @Test func countsOnlySelectedInterfaceAndPreserves64BitCounters() {
    var sampler = NetworkSampler()
    let base: UInt64 = 5_000_000_000
    let initial = [counter("en0", base), counter("utun0", base * 2, index: 2)]
    let first = sampler.sample(counters: initial, interfaceName: "en0", time: 1_000_000_000)
    #expect(first.downloadBytesPerSecond == 0)
    let next = [counter("en0", base + 2_670_000), counter("utun0", base * 2 + 5_000_000, index: 2)]
    let rate = sampler.sample(counters: next, interfaceName: "en0", time: 2_000_000_000)
    #expect(rate.downloadBytesPerSecond == 2_670_000)
    #expect(rate.uploadBytesPerSecond == 267_000)
    #expect(rate.totalDownloaded == base + 2_670_000)
    #expect(rate.interfaceName == "en0")
  }

  @Test func switchingInterfacesAndRecreatingThemStartsNewBaseline() {
    var sampler = NetworkSampler()
    _ = sampler.sample(counters: [counter("en0", 100)], interfaceName: "en0", time: 1_000_000_000)
    let tunnel = sampler.sample(
      counters: [counter("utun0", 50_000)], interfaceName: "utun0", time: 2_000_000_000)
    #expect(tunnel.downloadBytesPerSecond == 0)
    #expect(tunnel.totalDownloaded == 50_000)
    let recreated = sampler.sample(
      counters: [counter("utun0", 90_000, index: 2)], interfaceName: "utun0", time: 3_000_000_000)
    #expect(recreated.downloadBytesPerSecond == 0)
    let next = sampler.sample(
      counters: [counter("utun0", 100_000, index: 2)], interfaceName: "utun0", time: 5_000_000_000)
    #expect(next.downloadBytesPerSecond == 5_000)
  }

  @Test func disappearingOrResettingInterfaceDoesNotFallbackOrSpike() {
    var sampler = NetworkSampler()
    _ = sampler.sample(
      counters: [counter("en0", 10_000)], interfaceName: "en0", time: 1_000_000_000)
    let missing = sampler.sample(
      counters: [counter("en1", 20_000)], interfaceName: "en0", time: 2_000_000_000)
    #expect(missing.interfaceName == nil)
    #expect(missing.totalDownloaded == 0)
    let returned = sampler.sample(
      counters: [counter("en0", 30_000)], interfaceName: "en0", time: 3_000_000_000)
    #expect(returned.downloadBytesPerSecond == 0)
    let reset = sampler.sample(
      counters: [counter("en0", 50)], interfaceName: "en0", time: 4_000_000_000)
    #expect(reset.downloadBytesPerSecond == 0)
    let next = sampler.sample(
      counters: [counter("en0", 150)], interfaceName: "en0", time: 5_000_000_000)
    #expect(next.downloadBytesPerSecond == 100)
    var down = counter("en0", 500)
    down.flags = 0
    #expect(
      sampler.sample(counters: [down], interfaceName: "en0", time: 6_000_000_000).interfaceName
        == nil)
  }

  @Test(arguments: ["IPv4", "IPv6"])
  func automaticSelectionUsesPhysicalServiceBehindTunnel(family: String) {
    let counters = [counter("en0", 100), counter("en5", 200), counter("utun0", 400)]
    var state: [String: [String: Any]] = [
      "State:/Network/Global/\(family)": ["PrimaryInterface": "utun0"],
      "Setup:/Network/Global/IPv4": ["ServiceOrder": ["vpn", "ethernet", "wifi"]],
      "Setup:/Network/Service/vpn/Interface": ["Type": "PPP"],
      "Setup:/Network/Service/ethernet/Interface": ["Type": "Ethernet"],
      "Setup:/Network/Service/wifi/Interface": ["Type": "IEEE80211"],
      "State:/Network/Service/vpn/\(family)": ["InterfaceName": "utun0", "Router": "test"],
      "State:/Network/Service/ethernet/\(family)": ["InterfaceName": "en5", "Router": "test"],
      "State:/Network/Service/wifi/\(family)": ["InterfaceName": "en0", "Router": "test"],
    ]
    #expect(NetworkSampler.automaticInterface(counters: counters, state: state) == "en5")
    state["State:/Network/Global/\(family)"] = ["PrimaryInterface": "en0"]
    #expect(NetworkSampler.automaticInterface(counters: counters, state: state) == "en0")
    state["State:/Network/Global/\(family)"] = ["PrimaryInterface": "utun0"]
    state.removeValue(forKey: "State:/Network/Service/ethernet/\(family)")
    #expect(NetworkSampler.automaticInterface(counters: counters, state: state) == "en0")
    #expect(
      NetworkSampler.automaticInterface(counters: [counter("utun0", 400)], state: state) == nil)
    #expect(NetworkSampler.automaticInterface(counters: counters, state: [:]) == nil)
  }
}
