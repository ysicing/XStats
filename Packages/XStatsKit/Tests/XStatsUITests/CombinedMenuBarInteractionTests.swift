// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
@testable import Localization
import SwiftUI
import Testing
import WidgetData
@testable import XStatsUI

@MainActor
struct CombinedMenuBarInteractionTests {
  @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
  func settingFitsTranslatedLabels(language: AppLanguage) throws {
    let catalog = Translations.catalog(for: language)
    let title =
      language == .chinese
      ? "点击指标打开详情" : try #require(catalog?.translate("点击指标打开详情"))
    let subtitle =
      language == .chinese
      ? "右键菜单可打开状态总览" : try #require(catalog?.translate("右键菜单可打开状态总览"))
    let host = NSHostingView(
      rootView: SettingsGroup {
        GroupRow(showsDivider: false) {
          SettingRow(title: title, subtitle: subtitle) {
            DSToggle(isOn: .constant(true), label: title)
          }
        }
      }
      .environment(\.layoutDirection, language == .arabic ? .rightToLeft : .leftToRight)
      .environment(\.isSnapshot, true)
      .frame(width: 480))
    let size = host.fittingSize
    #expect(size.width == 480 && size.height >= 40 && size.height < 160)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let path = ProcessInfo.processInfo.environment["XSTATS_COMBINED_SETTINGS_PREVIEW_DIR"] {
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: path).appendingPathComponent("\(language.rawValue).png"))
    }
  }

  @Test func preferenceDefaultsOffAndSurvivesPersistenceAndBackups() throws {
    let suite = "CombinedMenuBarPreference.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.combinedItemDetailsEnabled)
    settings.combinedItemDetailsEnabled = true
    #expect(AppSettings(defaults: defaults).combinedItemDetailsEnabled)
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(settings.combinedItemDetailsEnabled)
    let document = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    settings.combinedItemDetailsEnabled = false
    settings.apply(document)
    #expect(settings.combinedItemDetailsEnabled)
    var disabled = SettingsDocument()
    disabled.combinedItemDetailsEnabled = false
    settings.apply(disabled)
    #expect(!AppSettings(defaults: defaults).combinedItemDetailsEnabled)
  }

  @Test func hitRegionsFollowStylesSpacingReadingsAndKeepAwakeMarker() throws {
    let items: [MenuBarItem] = [.cpu, .network, .disk, .battery, .aiUsage, .memory]
    var reading = MenuBarReading()
    reading.cpu = 0.27
    reading.memory = 0.64
    reading.upload = 12_345
    reading.download = 98_765_432
    reading.bluetoothDevice = ("computermouse", 58)
    reading.networkLocationStyle = .text
    reading.networkCountryCode = "US"
    reading.aiQuotas = ["claude", "codex", "grok", "gemini"].map {
      WidgetSnapshot.Quota(
        provider: $0, kind: "7 days", remainingPercent: 72, resetsAt: nil,
        fetchedAt: Date(), isStale: false)
    }
    for style in MenuBarStyle.allCases {
      for gap in [CGFloat(4), 12] {
        for awake in [false, true] {
          reading.keepAwake = awake
          let rendering = MenuBarRenderer.render(
            reading: reading, items: items, style: { _ in style },
            networkStyle: .arrows, colorizeHighLoad: true, fahrenheit: false, itemGap: gap)
          let imageFrame = NSRect(
            x: 6, y: 2, width: rendering.image.size.width, height: rendering.image.size.height)
          var previous: NSRect?
          for item in items {
            let frame = try #require(rendering.frame(for: item, in: imageFrame))
            #expect(frame.width > 0)
            for x in [frame.minX + 0.1, frame.midX, frame.maxX - 0.1] {
              #expect(rendering.item(at: NSPoint(x: x, y: frame.midY), in: imageFrame) == item)
            }
            if let previous {
              #expect(frame.minX - previous.maxX == gap)
              #expect(
                rendering.item(
                  at: NSPoint(x: previous.maxX + gap / 2, y: frame.midY), in: imageFrame) == nil)
            }
            previous = frame
          }
          #expect(rendering.item(at: NSPoint(x: 0, y: imageFrame.midY), in: imageFrame) == nil)
          #expect(rendering.item(at: NSPoint(x: imageFrame.midX, y: 30), in: imageFrame) == nil)
          if awake {
            #expect(
              rendering.item(
                at: NSPoint(x: imageFrame.minX + 1, y: imageFrame.midY), in: imageFrame) == nil)
          }
        }
      }
    }
    let empty = MenuBarRenderer.render(
      reading: reading, items: [], style: { _ in .stacked }, networkStyle: .arrows,
      colorizeHighLoad: false, fahrenheit: false)
    #expect(empty.itemFrames.isEmpty && empty.image.size.width > 0)
  }

  @Test func nativeClicksSwitchDetailsAndReleaseDemandOnClose() throws {
    _ = NSApplication.shared
    let suite = "CombinedMenuBarClicks.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      magpieClient: UnavailableMagpieClient())
    let settings = model.settings
    settings.menuBarLayout = .combined
    settings.menuBarItems = [.cpu, .memory, .disk, .battery, .aiUsage]
    settings.historyEnabled = false
    settings.enabledAlerts = []
    let controller = MenuBarController(model: model)
    let existingWindows = Set(NSApp.windows.map(\.windowNumber))
    controller.update()
    defer { controller.dismissPopovers() }
    let button = try #require(controller.combinedButton)

    // 使用真实 AppKit 图像区域和窗口坐标构造鼠标事件，不手填指标宽度。
    @discardableResult func click(
      _ item: MenuBarItem?, forwardedEventItem: MenuBarItem? = nil
    ) throws -> NSEvent {
      let rendering = MenuBarRenderer.render(
        reading: MenuBarReading(model: model, items: model.drawnMenuBarItems),
        items: model.drawnMenuBarItems, style: { settings.style(for: $0) },
        networkStyle: settings.networkStyle, colorizeHighLoad: settings.colorizeHighLoad,
        fahrenheit: settings.useFahrenheit, itemGap: CGFloat(settings.menuBarItemSpacing))
      let imageFrame = try #require(button.cell?.imageRect(forBounds: button.bounds))
      let frame =
        if let item {
          try #require(rendering.frame(for: item, in: imageFrame))
        } else {
          button.bounds
        }
      let point = button.convert(
        NSPoint(x: item == nil ? button.bounds.minX : frame.midX, y: frame.midY), to: nil)
      let window = try #require(button.window)
      let eventPoint: NSPoint
      if let forwardedEventItem {
        let forwardedFrame = try #require(rendering.frame(for: forwardedEventItem, in: imageFrame))
        eventPoint = button.convert(
          NSPoint(x: forwardedFrame.midX, y: forwardedFrame.midY), to: nil)
      } else {
        eventPoint = point
      }
      let event = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseUp, location: eventPoint, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil,
          eventNumber: 1, clickCount: 1, pressure: 0))
      controller.handleClick(
        button, event: event,
        pointerLocationInScreen: forwardedEventItem == nil
          ? nil : window.convertPoint(toScreen: point))
      return event
    }

    try click(.cpu)
    #expect(model.isCombinedPopoverOpen && model.openPopover == nil)
    controller.dismissPopovers()
    #expect(!model.demand.processes)

    settings.combinedItemDetailsEnabled = true
    controller.update()
    let actions = try #require(button.accessibilityCustomActions())
    #expect(actions.count == 6)
    for _ in 0..<3 {
      try click(.cpu)
      #expect(model.openPopover == .cpu && !model.isCombinedPopoverOpen)
      #expect(model.demand.processes)
      try click(.memory)
      #expect(model.openPopover == .memory && !model.isCombinedPopoverOpen)
      try click(.memory)
      #expect(model.openPopover == nil && !model.isCombinedPopoverOpen)
      #expect(!model.demand.processes)
    }

    for item: MenuBarItem in [.battery, .aiUsage, .battery, .cpu, .aiUsage, .battery] {
      try click(item)
      #expect(model.openPopover == item && !model.isCombinedPopoverOpen)
    }
    controller.dismissPopovers()

    // 系统转发事件的落点与实际鼠标位置不同时，SSD 和电池不能误开 AI。
    for item: MenuBarItem in [.disk, .battery] {
      try click(item, forwardedEventItem: .aiUsage)
      #expect(model.openPopover == item)
      controller.dismissPopovers()
    }
    try click(nil, forwardedEventItem: .aiUsage)
    #expect(model.isCombinedPopoverOpen && model.openPopover == nil)
    controller.dismissPopovers()

    let up = try click(.cpu)
    let down = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: up.locationInWindow, modifierFlags: [],
        timestamp: 0, windowNumber: up.windowNumber, context: nil,
        eventNumber: 2, clickCount: 1, pressure: 0))
    let visiblePanel = try #require(
      NSApp.windows.compactMap { $0 as? StatusPanel }.first {
        $0.isVisible
      })
    visiblePanel.dismiss(triggeredBy: down)
    try click(.cpu)
    #expect(model.openPopover == nil)
    // 同一次点击的 mouse-up 不重开，下一次独立点击不受冷却时间影响。
    try click(.cpu)
    #expect(model.openPopover == .cpu)
    controller.dismissPopovers()

    #expect(actions.first?.handler?() == true)
    #expect(model.openPopover == .cpu)
    controller.dismissPopovers()
    controller.handleClick(button, event: nil)
    #expect(model.isCombinedPopoverOpen && model.openPopover == nil)
    controller.dismissPopovers()
    try click(nil)
    #expect(model.isCombinedPopoverOpen && model.openPopover == nil)
    controller.dismissPopovers()

    let overviewAction = try #require(
      controller.contextMenu().items.first { $0.action == NSSelectorFromString("openOverview") })
    #expect(
      NSApp.sendAction(try #require(overviewAction.action), to: overviewAction.target, from: nil))
    #expect(model.isCombinedPopoverOpen)
    try click(.cpu)
    #expect(model.openPopover == .cpu && !model.isCombinedPopoverOpen)
    settings.combinedItemDetailsEnabled = false
    controller.update()
    #expect(model.openPopover == nil && !model.demand.processes)
    #expect(button.accessibilityCustomActions()?.isEmpty != false)

    settings.combinedItemDetailsEnabled = true
    controller.update()
    try click(.memory)
    settings.menuBarItems = [.cpu]
    controller.update()
    #expect(model.openPopover == nil && !model.demand.processes)
    // 快捷入口仍可打开未放在菜单栏里的项目。
    #expect(controller.showPopover(.memory))
    controller.update()
    #expect(model.openPopover == .memory)
    controller.dismissPopovers()
    #expect(controller.showPopover(.cpu))
    settings.menuBarLayout = .iconOnly
    controller.update()
    #expect(model.openPopover == nil && !model.isCombinedPopoverOpen)
    #expect(controller.combinedButton?.accessibilityCustomActions()?.isEmpty != false)
    let panels = NSApp.windows.filter { !existingWindows.contains($0.windowNumber) }
      .compactMap { $0 as? StatusPanel }
    #expect(panels.allSatisfy { !$0.isVisible && $0.contentView == nil })
  }
}
