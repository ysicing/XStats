// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Metrics

struct WiFiLinkTests {
  @Test func partialReadingsKeepAvailableConnectionDetails() {
    let link = WiFiLink(
      ssid: nil, rssi: 0, noise: 0, transmitRate: 0,
      bssid: nil, bandGHz: 6, channel: 37, channelWidthMHz: 160,
      phyMode: "802.11ax", security: "WPA3 Personal")
    #expect(link.rssi == nil && link.noise == nil && link.transmitRate == nil)
    #expect(link.signalToNoiseRatio == nil)
    #expect(link.channel == 37 && link.bandGHz == 6 && link.phyMode == "802.11ax")
  }

  @Test func signalToNoiseRequiresValidMeasurements() {
    let good = WiFiLink(ssid: "Office", rssi: -58, noise: -92, transmitRate: 866.7)
    #expect(good.signalToNoiseRatio == 34)
    #expect(good.transmitRate == 866.7)
    for noise in [0, 10, -40] {
      let invalid = WiFiLink(ssid: nil, rssi: -58, noise: noise, transmitRate: .infinity)
      #expect(invalid.signalToNoiseRatio == nil && invalid.transmitRate == nil)
    }
  }

  @Test(arguments: [
    (nil as Int?, NetworkIconState.unknown),
    (0, .unknown), (10, .unknown),
    (-59, .wifi(bars: 3)), (-60, .wifi(bars: 3)),
    (-61, .wifi(bars: 2)), (-75, .wifi(bars: 2)), (-76, .wifi(bars: 1)),
  ])
  func signalIconPreservesUnknownReadingsAndThresholds(rssi: Int?, expected: NetworkIconState) {
    let link = WiFiLink(ssid: nil, rssi: rssi, noise: nil, transmitRate: nil)
    #expect(NetworkIconState(wifiRSSI: link.rssi) == expected)
  }
}
