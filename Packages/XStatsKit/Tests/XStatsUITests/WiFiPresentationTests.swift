// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct WiFiPresentationTests {
  @Test func wirelessDetailsFitAndMeasureConsistentlyBeforeAndAfterMounting() throws {
    let suite = "WiFiPresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = []
    settings.menuBarItems = []
    settings.historyEnabled = false
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    let wifi = WiFiLink(
      ssid: "Example Wi-Fi with a very long network name", rssi: -58, noise: -92,
      transmitRate: 866.7, bssid: "02:00:00:00:00:01", bandGHz: 5, channel: 149,
      channelWidthMHz: 80, phyMode: "802.11ax", security: "WPA2/WPA3 Personal")
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      var collapsedHeight: CGFloat = 0
      for expanded in [false, true] {
        settings.wifiDetailsExpanded = expanded
        let host = NSHostingView(
          rootView: Card { WiFiConnectionRows(wifi: wifi) }
            .environment(model).environment(\.isSnapshot, true)
            .environment(\.layoutDirection, direction).frame(width: DS.Size.popoverWidth))
        let size = host.fittingSize
        #expect(abs(size.width - DS.Size.popoverWidth) < 1 && size.height > 0 && size.height < 650)
        if expanded {
          #expect(size.height > collapsedHeight + 60)
        } else {
          collapsedHeight = size.height
        }
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - size.height) < 1)
        if let path = ProcessInfo.processInfo.environment["XSTATS_WIFI_PREVIEW_DIR"] {
          let directory = URL(fileURLWithPath: path, isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: directory.appendingPathComponent("wifi-\(expanded)-\(direction).png"))
        }
        window.close()
      }
    }
    // 界面展开和排序偏好不应启用任何监控或采样。
    #expect(settings.enabledMonitoringModules.isEmpty && !model.demand.hasSamples)
  }
}
