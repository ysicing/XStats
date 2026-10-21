// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Metrics

struct NetworkIconStateTests {
  @Test(arguments: [
    (false, nil as NetworkIconPathMonitor.State?, NetworkIconState.ethernet),
    (false, .init(satisfied: true, wifi: true, expensive: true), .ethernet),
    (false, .init(satisfied: false, wifi: false, expensive: false), .noInternet),
    (true, .init(satisfied: false, wifi: true, expensive: true), .noInternet),
  ])
  func specialConnectionsSkipSignalReading(
    isWiFi: Bool, path: NetworkIconPathMonitor.State?, expected: NetworkIconState
  ) {
    var signalReads = 0
    let state = NetworkIconState.connected(isWiFi: isWiFi, path: path) {
      signalReads += 1
      return -60
    }
    #expect(state == expected)
    #expect(signalReads == 0)
  }

  @Test(arguments: [false, true])
  func wifiCostDoesNotIdentifyPersonalHotspot(expensive: Bool) {
    let path = NetworkIconPathMonitor.State(satisfied: true, wifi: true, expensive: expensive)
    #expect(NetworkIconState.connected(isWiFi: true, path: path, rssi: { -61 }) == .wifi(bars: 2))
  }

  @Test func pathArrivalAndChangesBypassOnlyTheConnectionReadThrottle() {
    var sampler = NetworkSampler()
    var reads = 0
    let read: (NetworkIconPathMonitor.State?) -> NetworkIconState = { path in
      reads += 1
      return path?.satisfied == false ? .noInternet : .wifi(bars: 2)
    }
    #expect(sampler.sampleConnection(uptime: 100, path: nil, read: read) == .wifi(bars: 2))
    #expect(sampler.sampleConnection(uptime: 100.1, path: nil, read: read) == .wifi(bars: 2))
    #expect(reads == 1)
    let offline = NetworkIconPathMonitor.State(satisfied: false, wifi: true, expensive: false)
    #expect(sampler.sampleConnection(uptime: 100.2, path: offline, read: read) == .noInternet)
    #expect(reads == 2)
    #expect(sampler.sampleConnection(uptime: 104.1, path: offline, read: read) == .noInternet)
    #expect(reads == 2)
    #expect(sampler.sampleConnection(uptime: 104.3, path: offline, read: read) == .noInternet)
    #expect(reads == 3)
    let online = NetworkIconPathMonitor.State(satisfied: true, wifi: true, expensive: false)
    #expect(sampler.sampleConnection(uptime: 104.4, path: online, read: read) == .wifi(bars: 2))
    #expect(reads == 4)
    sampler.stopConnectionMonitoring()
    #expect(sampler.sampleConnection(uptime: 104.5, path: online, read: read) == .wifi(bars: 2))
    #expect(reads == 5)
  }

  @Test(arguments: [
    (nil as Int?, NetworkIconState.unknown), (0, .unknown), (10, .unknown),
    (-60, .wifi(bars: 3)), (-61, .wifi(bars: 2)), (-76, .wifi(bars: 1)),
  ])
  func wifiUsesOnlyAvailableSignalMeasurements(rssi: Int?, expected: NetworkIconState) {
    // VPN 路径未标成 Wi-Fi 时，仍以选出的物理接口类型和 RSSI 为准。
    let path = NetworkIconPathMonitor.State(satisfied: true, wifi: false, expensive: true)
    var signalReads = 0
    let state = NetworkIconState.connected(isWiFi: true, path: path) {
      signalReads += 1
      return rssi
    }
    #expect(state == expected)
    #expect(signalReads == 1)
  }
}
