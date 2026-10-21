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
    (true, .init(satisfied: true, wifi: true, expensive: true), .hotspot),
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
