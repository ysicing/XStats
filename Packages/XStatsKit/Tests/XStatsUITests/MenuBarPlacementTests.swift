// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
@testable import Localization
import Metrics
import SMC
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct MenuBarPlacementTests {
  private func withModel(_ body: (AppModel, UserDefaults) throws -> Void) throws {
    let suite = "MenuBarPlacementTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.historyEnabled = false
    settings.enabledAlerts = []
    let model = AppModel(
      settings: settings, historyURL: nil,
      magpieClient: UnavailableMagpieClient())
    try body(model, defaults)
  }

  @Test(arguments: [false, true], [false, true])
  func destinationsAreIndependent(menu: Bool, overview: Bool) throws {
    try withModel { model, defaults in
      let settings = model.settings
      settings.menuBarLayout = .combined
      settings.customMenuBarPlacementEnabled = true
      settings.menuBarItems = []
      settings.combinedOverviewItems = []
      settings.setEnabled(.cpu, menu)
      settings.setOverviewEnabled(.cpu, overview)
      #expect(model.drawnMenuBarItems == (menu ? [.cpu] : []))
      #expect(model.visibleOverviewItems == (overview ? [.cpu] : []))
      #expect(settings.isModuleEnabled(.cpu))
      model.isCombinedPopoverOpen = true
      #expect(model.demand.cpu == (menu || overview))
      model.isCombinedPopoverOpen = false
      #expect(model.demand.cpu == menu)
      let restored = AppSettings(defaults: defaults)
      #expect(restored.menuBarItems == settings.menuBarItems)
      #expect(restored.combinedOverviewItems == settings.combinedOverviewItems)
      if !menu {
        let image = MenuBarRenderer.image(for: model)
        #expect(image.size.width > 0 && image.size.height > 0)
      }
    }
  }

  @Test func defaultFollowsMenuAndFirstCustomizationCopiesCurrentSelection() throws {
    for items in [[], ["gpu", "network"]] {
      let suite = "MenuBarPlacementMigrationTests.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(items, forKey: "menuBarItems")
      let settings = AppSettings(defaults: defaults)
      settings.menuBarLayout = .combined
      #expect(!settings.customMenuBarPlacementEnabled)
      #expect(settings.combinedOverviewItems == settings.menuBarItems)
      let selection: Set<MenuBarItem> = items.isEmpty ? [.cpu] : []
      settings.menuBarItems = selection
      #expect(Set(settings.orderedOverviewItems) == selection)
      settings.customMenuBarPlacementEnabled = true
      #expect(settings.combinedOverviewItems == selection)
      settings.combinedOverviewItems = []
      #expect(AppSettings(defaults: defaults).combinedOverviewItems.isEmpty)
      #expect(AppSettings(defaults: defaults).customMenuBarPlacementEnabled)
    }
  }

  @Test func disablingCustomizationFollowsMenuAndPreservesCustomSelection() throws {
    try withModel { model, defaults in
      let settings = model.settings
      settings.menuBarLayout = .combined
      settings.menuBarItems = [.cpu]
      settings.customMenuBarPlacementEnabled = true
      settings.combinedOverviewItems = [.gpu, .audio]
      model.isCombinedPopoverOpen = true
      #expect(model.demand.gpu && model.audioMenuVisible)
      settings.customMenuBarPlacementEnabled = false
      #expect(model.visibleOverviewItems == [.cpu])
      #expect(!model.demand.gpu && !model.audioMenuVisible)
      settings.menuBarItems = [.network]
      #expect(model.visibleOverviewItems == [.network])
      #expect(settings.combinedOverviewItems == [.gpu, .audio])
      let restored = AppSettings(defaults: defaults)
      #expect(!restored.customMenuBarPlacementEnabled)
      #expect(restored.orderedOverviewItems == [.network])
      restored.customMenuBarPlacementEnabled = true
      #expect(Set(restored.orderedOverviewItems) == [.gpu, .audio])
      #expect(restored.menuBarItems == [.network])
    }
  }

  @Test func importingAnEmptyOverviewPreservesItWhenCustomizationFirstEnables() throws {
    let suite = "MenuBarPlacementImportTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set([], forKey: "menuBarItems")
    let restored = AppSettings(defaults: defaults)
    var document = SettingsDocument()
    document.menuBarLayout = MenuBarLayout.combined.rawValue
    document.menuBarItems = ["cpu"]
    document.combinedOverviewItems = []
    document.customMenuBarPlacementEnabled = true
    restored.apply(document)
    #expect(restored.customMenuBarPlacementEnabled)
    #expect(restored.menuBarItems == [.cpu])
    #expect(restored.orderedOverviewItems.isEmpty)
    #expect(AppSettings(defaults: defaults).combinedOverviewItems.isEmpty)
  }

  @Test func overviewFollowsSharedOrderAndOtherLayoutsKeepTheirSelection() throws {
    try withModel { model, _ in
      let settings = model.settings
      settings.menuBarLayout = .combined
      settings.customMenuBarPlacementEnabled = true
      settings.menuBarItems = [.cpu]
      settings.combinedOverviewItems = [.network, .gpu]
      settings.setMenuBarOrder([.gpu, .cpu, .network])
      #expect(model.visibleOverviewItems == [.gpu, .network])
      settings.moveMenuBarItem(.network, by: -1)
      #expect(model.visibleOverviewItems == [.gpu, .network])
      settings.moveMenuBarItem(.network, by: -1)
      #expect(model.visibleOverviewItems == [.network, .gpu])
      #expect(model.drawnMenuBarItems == [.cpu])
      for layout in [MenuBarLayout.separate, .iconOnly] {
        settings.menuBarLayout = layout
        #expect(model.visibleOverviewItems == [.cpu])
      }
      settings.menuBarLayout = .combined
      #expect(model.visibleOverviewItems == [.network, .gpu])
    }
  }

  @Test func featureEnablementIsIndependentOfBothPlacements() throws {
    try withModel { model, _ in
      let settings = model.settings
      settings.customMenuBarPlacementEnabled = true
      settings.menuBarItems = []
      settings.combinedOverviewItems = []
      settings.enabledMonitoringModules = []
      settings.audioEnabled = false
      settings.aiUsageEnabled = false
      settings.combinedOverviewItems = [.cpu, .gpu, .audio, .aiUsage, .display, .battery]
      #expect(settings.isModuleEnabled(.cpu) && settings.isModuleEnabled(.gpu))
      #expect(settings.audioEnabled && settings.aiUsageEnabled)
      #expect(!settings.isModuleEnabled(.display) && !settings.isModuleEnabled(.battery))
      #expect(settings.menuBarItems.isEmpty)
      settings.setModuleEnabled(.cpu, false)
      settings.audioEnabled = false
      settings.aiUsageEnabled = false
      #expect(!model.visibleOverviewItems.contains(.cpu))
      #expect(!model.visibleOverviewItems.contains(.audio))
      #expect(!model.visibleOverviewItems.contains(.aiUsage))
      #expect(
        model.visibleOverviewItems.contains(.display)
          && model.visibleOverviewItems.contains(.battery))
      settings.setOverviewEnabled(.cpu, true)
      #expect(model.visibleOverviewItems.contains(.cpu))
      settings.setOverviewEnabled(.cpu, false)
      #expect(settings.isModuleEnabled(.cpu))
    }
  }

  @Test func overviewOnlyConsumersStopOnCloseAndStillDiscoverFans() throws {
    try withModel { model, _ in
      model.settings.menuBarLayout = .combined
      model.settings.customMenuBarPlacementEnabled = true
      model.settings.menuBarItems = []
      model.settings.combinedOverviewItems = [.gpu, .disk, .temperature, .fan, .audio, .battery]
      let idle = model.demand
      #expect(!idle.hasSamples && !model.audioMenuVisible && model.bluetoothDemand == .off)
      for _ in 0..<5 {
        model.isCombinedPopoverOpen = true
        let visible = model.demand
        #expect(visible.gpu && visible.disk && visible.fans && visible.battery)
        #expect(visible.temperatures.contains(.cpu) && visible.interval == .seconds(1))
        #expect(!visible.processes && !visible.diskDetail && !visible.power)
        #expect(model.audioMenuVisible)
        #expect(model.bluetoothDemand == (model.store.battery == nil ? .foreground : .off))
        model.isCombinedPopoverOpen = false
        #expect(model.demand == idle)
        #expect(!model.audioMenuVisible && model.bluetoothDemand == .off)
      }
      var snapshot = MetricsSnapshot()
      snapshot.sensors = SensorReadings(temperatures: [], fans: [], fanCount: 0)
      model.store.apply(snapshot)
      model.isCombinedPopoverOpen = true
      #expect(!model.demand.fans && !model.visibleOverviewItems.contains(.fan))
      #expect(model.settings.combinedOverviewItems.contains(.fan))
    }
  }

  @Test(arguments: [false, true])
  func backupRoundTripsAndOldDocumentsRestoreBothDestinations(custom: Bool) throws {
    try withModel { model, defaults in
      let settings = model.settings
      settings.menuBarLayout = .combined
      settings.customMenuBarPlacementEnabled = true
      settings.menuBarItems = [.cpu]
      settings.combinedOverviewItems = [.gpu, .audio]
      settings.customMenuBarPlacementEnabled = custom
      let document = try JSONDecoder().decode(
        SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
      settings.menuBarItems = [.memory]
      settings.combinedOverviewItems = []
      settings.customMenuBarPlacementEnabled = !custom
      settings.apply(document)
      #expect(settings.customMenuBarPlacementEnabled == custom)
      #expect(settings.menuBarItems == [.cpu])
      #expect(settings.combinedOverviewItems == [.gpu, .audio])
      let old = try JSONDecoder().decode(
        SettingsDocument.self, from: Data(#"{"schema":1,"menuBarItems":["network"]}"#.utf8))
      settings.apply(old)
      #expect(!settings.customMenuBarPlacementEnabled)
      #expect(settings.menuBarItems == [.network] && settings.combinedOverviewItems == [.network])
      var future = SettingsDocument()
      future.customMenuBarPlacementEnabled = true
      future.combinedOverviewItems = ["gpu", "unknown", "gpu"]
      future.enabledMonitoringModules = []
      settings.apply(future)
      #expect(settings.combinedOverviewItems == [.gpu])
      #expect(model.visibleOverviewItems.isEmpty && !model.demand.gpu)
      settings.apply(SettingsDocument())
      #expect(AppSettings(defaults: defaults).combinedOverviewItems == [.gpu])
      #expect(AppSettings(defaults: defaults).customMenuBarPlacementEnabled)
    }
  }

  @Test(arguments: [false, true])
  func settingsFitNarrowWidthsAndBothDirections(custom: Bool) throws {
    try withModel { model, _ in
      model.settings.menuBarLayout = .combined
      model.settings.customMenuBarPlacementEnabled = custom
      model.settings.menuBarItems = [.cpu]
      model.settings.combinedOverviewItems = [.cpu, .gpu]
      for width: CGFloat in [480, 800] {
        for rtl in [false, true] {
          let host = NSHostingView(
            rootView: VStack { MenuBarSettings() }
              .environment(model).environment(\.isSnapshot, true)
              .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
              .frame(width: width))
          let size = host.fittingSize
          #expect(abs(size.width - width) < 1 && size.height > 0)
          host.frame = CGRect(origin: .zero, size: size)
          host.layoutSubtreeIfNeeded()
          let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          if let output = ProcessInfo.processInfo.environment["XSTATS_PLACEMENT_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(
              at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
              to: directory.appendingPathComponent("placements-\(custom)-\(Int(width))-\(rtl).png"))
          }
        }
      }
      for language in AppLanguage.allCases where language != .system && language != .chinese {
        let table = try #require(Translations.catalog(for: language))
        #expect(table.translate("状态总览中还没有开启任何项目。")?.isEmpty == false)
        #expect(table.translate("自定义展示位置")?.isEmpty == false)
      }
    }
  }

  @Test func firstEnablingCustomPlacementKeepsDisabledFeaturesOff() throws {
    try withModel { model, _ in
      let settings = model.settings
      settings.setEnabled(.gpu, true)
      settings.setModuleEnabled(.gpu, false)
      let selection = settings.menuBarItems
      let modules = settings.enabledMonitoringModules
      #expect(!selection.contains(.gpu))
      settings.customMenuBarPlacementEnabled = true
      #expect(settings.combinedOverviewItems == selection)
      #expect(settings.enabledMonitoringModules == modules)
      #expect(!settings.isModuleEnabled(.gpu))
    }
  }
}
