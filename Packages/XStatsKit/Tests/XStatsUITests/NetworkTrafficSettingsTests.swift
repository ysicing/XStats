// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import Localization
@testable import Metrics
@testable import XStatsUI

@MainActor
struct NetworkTrafficSettingsTests {
  @Test func interfacePreferencePersistsLocallyAndFeedsSamplingDemand() {
    let suite = "NetworkTrafficSettingsTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.networkInterfaceName.isEmpty)
    let generation = settings.monitoringGeneration
    settings.networkInterfaceName = "utun99"
    #expect(settings.monitoringGeneration == generation + 1)
    #expect(AppSettings(defaults: defaults).networkInterfaceName == "utun99")
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [],
      networkCacheDefaults: defaults)
    #expect(model.demand.networkInterfaceName == "utun99")
    var stale = MetricsSnapshot()
    stale.samplingGeneration = generation
    stale.network = NetworkRate(
      interfaceName: "en0", downloadBytesPerSecond: 9000,
      uploadBytesPerSecond: 0, totalDownloaded: 9000, totalUploaded: 0)
    model.handle(stale)
    #expect(model.store.network == nil)

    settings.setModuleEnabled(.network, false)
    #expect(!model.demand.network)
    #expect(settings.networkInterfaceName == "utun99")
    settings.networkInterfaceName = ""
    #expect(model.demand.networkInterfaceName.isEmpty)
  }

  @Test func resetTotalsNeverSubtractAnotherInterfaceOrOldAggregate() throws {
    let suite = "NetworkTrafficBaselineTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let controller = NetworkController(settings: settings, cacheDefaults: defaults)
    let first = NetworkRate(
      interfaceName: "en0", downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
      totalDownloaded: 1000, totalUploaded: 500)
    controller.resetTraffic(first)
    var next = first
    next.totalDownloaded = 1300
    next.totalUploaded = 600
    controller.reconcileTrafficBaseline(next)
    #expect(controller.trafficTotals(next).download == 300)
    #expect(controller.trafficTotals(next).upload == 100)
    let restored = NetworkController(settings: settings, cacheDefaults: defaults)
    #expect(restored.trafficTotals(next).download == 300)

    next.interfaceName = "en5"
    controller.reconcileTrafficBaseline(next)
    #expect(controller.trafficBaseline == nil)
    #expect(controller.trafficTotals(next).download == 1300)
    controller.resetTraffic(next)
    next.totalDownloaded = 20
    controller.reconcileTrafficBaseline(next)
    #expect(controller.trafficBaseline == nil)
    controller.resetTraffic(first)
    var high = first
    high.totalDownloaded = 5000
    var rolledBack = first
    rolledBack.totalDownloaded = 2000
    controller.reconcileTrafficBaseline(rolledBack, previous: high)
    #expect(controller.trafficBaseline == nil)
    controller.resetTraffic(first)
    var recreated = first
    recreated.interfaceIndex = 99
    controller.reconcileTrafficBaseline(recreated)
    #expect(controller.trafficBaseline == nil)
    // 模拟旧版本无接口身份的累计基线，即使开机时间相同也必须丢弃。
    var legacy = try #require(restored.trafficBaseline)
    legacy.interfaceName = nil
    defaults.set(try JSONEncoder().encode(legacy), forKey: "trafficBaseline")
    #expect(NetworkController(settings: settings, cacheDefaults: defaults).trafficBaseline == nil)
  }

  @Test func translationsAndNarrowLayout() throws {
    let keys = ["流量统计接口", "自动（物理接口）", "{}（不可用）"]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys { #expect(table.translate(key)?.isEmpty == false) }
    }
    let suite = "NetworkTrafficLayoutTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.networkInterfaceName = "utun99"
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [],
      networkCacheDefaults: defaults)
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let host = NSHostingView(
        rootView: NetworkTrafficSettings()
          .environment(model).environment(\.isSnapshot, true)
          .environment(\.layoutDirection, direction).frame(width: 330))
      #expect(host.fittingSize.width == 330)
      #expect(host.fittingSize.height > 0 && host.fittingSize.height < 100)
      host.frame = CGRect(origin: .zero, size: host.fittingSize)
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      #expect(bitmap.pixelsWide > 0)
    }
  }
}
