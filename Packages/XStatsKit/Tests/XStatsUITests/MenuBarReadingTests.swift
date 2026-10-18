// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Observation
import SMC
import Testing
import AIUsage
@testable import Metrics
@testable import XStatsUI

@MainActor
struct MenuBarReadingTests {
  @Test(arguments: [MenuBarStyle.ring, .pie, .history, .line, .meter, .dot], [false, true])
  func warningColorsLeaveGraphicalTextNeutral(style: MenuBarStyle, dark: Bool) throws {
    for value in [0.85, 0.95, 1.0] {
      var reading = MenuBarReading()
      reading.cpu = value
      reading.gpu = value
      reading.memory = value
      reading.disk = value
      reading.cpuHistory = [value, value]
      reading.gpuHistory = [value, value]
      reading.memoryHistory = [value, value]
      reading.diskHistory = [value, value]
      reading.battery = 1 - value
      reading.batteryHistory = [1 - value, 1 - value]
      for item: MenuBarItem in [.cpu, .gpu, .memory, .disk, .battery] {
        for valueOnTop in [false, true] {
          let reference = MenuBarRenderer.image(
            reading: reading, items: [item], style: { _ in .stackedCenter }, networkStyle: .dots,
            colorizeHighLoad: false, fahrenheit: false, valueOnTop: valueOnTop)
          let textWidth = Int(reference.size.width * 2)
          let bitmaps = try [false, true].map { enabled in
            let image = MenuBarRenderer.image(
              reading: reading, items: [item], style: { _ in style }, networkStyle: .dots,
              colorizeHighLoad: enabled, fahrenheit: false, valueOnTop: valueOnTop)
            let preview = MenuBarRenderer.preview(image, dark: dark, backingScale: 2)
            let data = try #require(preview.tiffRepresentation)
            return try #require(NSBitmapImageRep(data: data)?.cgImage)
          }
          let text = try bitmaps.map { bitmap in
            let crop = try #require(
              bitmap.cropping(
                to: CGRect(
                  x: bitmap.width - textWidth, y: 0,
                  width: textWidth, height: bitmap.height)))
            return NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])
          }
          #expect(text[0] == text[1], "\(item) 的 \(style) 只应给图形着色")
          #expect(
            NSBitmapImageRep(cgImage: bitmaps[0]).tiffRepresentation
              != NSBitmapImageRep(cgImage: bitmaps[1]).tiffRepresentation)
        }
      }
    }
  }

  @Test(arguments: MenuBarStyle.allCases, [false, true])
  func loadColorsRespectThresholdsAndToggle(style: MenuBarStyle, dark: Bool) throws {
    for item: MenuBarItem in [.cpu, .gpu, .memory, .disk, .battery] {
      for (value, expected) in [
        (0.0, 0), (0.1, 0), (0.2, 0), (0.201, 0),
        (0.799, 0), (0.8, 1), (0.899, 1), (0.9, 2), (1.0, 2),
      ] {
        var reading = MenuBarReading()
        reading.cpu = value
        reading.gpu = value
        reading.memory = value
        reading.disk = value
        reading.cpuHistory = [value, value]
        reading.gpuHistory = [value, value]
        reading.memoryHistory = [value, value]
        reading.diskHistory = [value, value]
        // 用同一组边界验证“使用率高”和“剩余电量低”两个方向。
        let remaining = value == 0.8 ? 0.2 : value == 0.9 ? 0.1 : 1 - value
        reading.battery = remaining
        reading.batteryHistory = [remaining, remaining]
        for enabled in [false, true] {
          try expectLoadColor(
            reading: reading, item: item, style: style, dark: dark,
            enabled: enabled, expected: enabled ? expected : 0)
        }
      }
    }
    for item: MenuBarItem in [.cpu, .gpu, .memory, .disk, .battery] {
      try expectLoadColor(
        reading: MenuBarReading(), item: item, style: style, dark: dark,
        enabled: true, expected: 0)
    }
    for (percent, expected) in [(0, 2), (10, 2), (11, 1), (20, 1), (21, 0), (100, 0)] {
      var reading = MenuBarReading()
      reading.bluetoothDevice = ("headphones", percent)
      for enabled in [false, true] {
        try expectLoadColor(
          reading: reading, item: .battery, style: style, dark: dark,
          enabled: enabled, expected: enabled ? expected : 0)
      }
    }
  }

  private func expectLoadColor(
    reading: MenuBarReading, item: MenuBarItem, style: MenuBarStyle,
    dark: Bool, enabled: Bool, expected: Int
  ) throws {
    let image = MenuBarRenderer.image(
      reading: reading, items: [item], style: { _ in style }, networkStyle: .dots,
      colorizeHighLoad: enabled, fahrenheit: false)
    #expect(image.isTemplate == (expected == 0), "\(item), \(style), \(enabled)")
    let preview = MenuBarRenderer.preview(image, dark: dark, backingScale: 2)
    let data = try #require(preview.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    var hasRed = false
    var hasOrange = false
    // 零电量图形只有半透明底槽，其余读数仍要求存在清晰可见的警示填充。
    let alphaThreshold = item == .battery && reading.battery == 0 ? 0.05 : 0.5
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          color.alphaComponent > alphaThreshold
        else { continue }
        let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
        hasRed = hasRed || (r > g * 1.8 && r > b * 1.8)
        hasOrange = hasOrange || (r > g * 1.1 && g > b * 1.8 && g > 0.25)
      }
    }
    #expect(
      hasRed == (expected == 2),
      "\(item), \(style), \(enabled), dark=\(dark)")
    #expect(hasOrange == (expected == 1), "\(item), \(style), \(enabled), dark=\(dark)")
  }

  @Test(arguments: MenuBarStyle.allCases)
  func loadColorToggleDoesNotChangeAIQuota(style: MenuBarStyle) throws {
    var reading = MenuBarReading()
    reading.aiQuotas = [
      MenuBarQuota(
        provider: .codex, window: AIQuotaWindow(kind: .weekly, usedPercent: 96, resetsAt: nil),
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), isStale: false)
    ]
    let images = [false, true].map { enabled in
      MenuBarRenderer.preview(
        MenuBarRenderer.image(
          reading: reading, items: [.aiUsage], style: { _ in style }, networkStyle: .dots,
          colorizeHighLoad: enabled, fahrenheit: false), dark: false, backingScale: 2)
    }
    #expect(images[0].tiffRepresentation == images[1].tiffRepresentation)
  }

  @Test func valuePositionPersistsAndRoundTripsWithoutChangingOldBackups() throws {
    let suite = "MenuBarValuePosition.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.menuBarValueOnTop)
    settings.menuBarValueOnTop = true
    #expect(AppSettings(defaults: defaults).menuBarValueOnTop)
    let document = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    settings.menuBarValueOnTop = false
    settings.apply(document)
    #expect(settings.menuBarValueOnTop)
    settings.apply(SettingsDocument())
    #expect(settings.menuBarValueOnTop)
  }

  @Test(arguments: [
    MenuBarStyle.stacked, .stackedCenter, .ring, .pie, .history, .line, .meter, .dot,
  ])
  func valuePositionSwapsTextRowsWithoutResizing(style: MenuBarStyle) throws {
    var reading = MenuBarReading.sample
    reading.keepAwake = false
    for item in MenuBarItem.allCases where item != .network {
      let images = try [false, true].map { valueOnTop in
        let image = MenuBarRenderer.image(
          reading: reading, items: [item], style: { _ in style }, networkStyle: .dots,
          colorizeHighLoad: false, fahrenheit: false, valueOnTop: valueOnTop)
        let preview = MenuBarRenderer.preview(image, dark: false, backingScale: 2)
        let data = try #require(preview.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: data).flatMap { $0.cgImage })
      }
      #expect(images[0].width == images[1].width)
      #expect(images[0].height == images[1].height)
      // 两个文字行相距 11pt；调换顺序时字形与字号应保持一致。
      let bottom = try #require(
        images[0].cropping(
          to: CGRect(
            x: 0, y: 22, width: images[0].width, height: 22)))
      let top = try #require(
        images[1].cropping(
          to: CGRect(
            x: 0, y: 0, width: images[1].width, height: 22)))
      if style == .stacked || style == .stackedCenter {
        #expect(
          NSBitmapImageRep(cgImage: bottom).tiffRepresentation
            == NSBitmapImageRep(cgImage: top).tiffRepresentation)
      }
      #expect(
        NSBitmapImageRep(cgImage: images[0]).tiffRepresentation
          != NSBitmapImageRep(cgImage: images[1]).tiffRepresentation)
    }
  }

  @Test(arguments: [
    MenuBarStyle.stacked, .stackedCenter, .ring, .pie, .history, .line, .meter, .dot,
  ])
  func valuePositionAppliesToQuotaAndBluetoothFallback(style: MenuBarStyle) throws {
    var quota = MenuBarReading.sample
    quota.aiQuotas = [
      MenuBarQuota(
        provider: nil, window: AIQuotaWindow(kind: .weekly, usedPercent: 19, resetsAt: nil),
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), isStale: false,
        magpieName: "Magpie")
    ]
    var bluetooth = MenuBarReading()
    bluetooth.bluetoothDevice = ("headphones", 19)
    for (reading, item) in [(quota, MenuBarItem.aiUsage), (bluetooth, .battery)] {
      let images = [false, true].map { valueOnTop in
        MenuBarRenderer.preview(
          MenuBarRenderer.image(
            reading: reading, items: [item], style: { _ in style }, networkStyle: .dots,
            colorizeHighLoad: false, fahrenheit: false, valueOnTop: valueOnTop),
          dark: false, backingScale: 2)
      }
      #expect(images[0].size == images[1].size)
      // 蓝牙在图形样式下保持单行图标 + 电量；AI 额度使用居中双行。
      if item == .battery && style != .stacked && style != .stackedCenter {
        #expect(images[0].tiffRepresentation == images[1].tiffRepresentation)
      } else {
        #expect(images[0].tiffRepresentation != images[1].tiffRepresentation)
        if style == .stacked || style == .stackedCenter {
          let bitmaps = try images.map { image in
            let data = try #require(image.tiffRepresentation)
            return try #require(NSBitmapImageRep(data: data)?.cgImage)
          }
          // 额度的来源名下移 10pt，给下伸字母留出 1pt；数字上移 11pt。
          // 裁出完整字形，避免把相邻行的下伸字母误算成数字的一部分。
          let rowCrops =
            item == .aiUsage
            ? [(beforeY: 2, afterY: 22, height: 22), (beforeY: 24, afterY: 2, height: 20)]
            : [(beforeY: 0, afterY: 22, height: 22), (beforeY: 22, afterY: 0, height: 22)]
          for row in rowCrops {
            let before = try #require(
              bitmaps[0].cropping(
                to: CGRect(
                  x: 0, y: row.beforeY, width: bitmaps[0].width, height: row.height)))
            let after = try #require(
              bitmaps[1].cropping(
                to: CGRect(
                  x: 0, y: row.afterY, width: bitmaps[1].width, height: row.height)))
            #expect(
              NSBitmapImageRep(cgImage: before).tiffRepresentation
                == NSBitmapImageRep(cgImage: after).tiffRepresentation,
              "调换位置不应裁切额度或蓝牙的文字：\(item)")
          }
        }
      }
    }
  }

  @Test func valuePositionPreservesSingleLineAndNetworkLayouts() {
    for style in [MenuBarStyle.inline, .icon] {
      let images = [false, true].map { valueOnTop in
        MenuBarRenderer.preview(
          MenuBarRenderer.image(
            reading: .sample, items: MenuBarItem.allCases, style: { _ in style },
            networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false,
            valueOnTop: valueOnTop), dark: false, backingScale: 2)
      }
      #expect(images[0].tiffRepresentation == images[1].tiffRepresentation)
    }
    for style in NetworkMenuStyle.allCases {
      let images = [false, true].map { valueOnTop in
        MenuBarRenderer.preview(
          MenuBarRenderer.image(
            reading: .sample, items: [.network], style: { _ in .stackedCenter },
            networkStyle: style, colorizeHighLoad: false, fahrenheit: false,
            valueOnTop: valueOnTop), dark: false, backingScale: 2)
      }
      #expect(images[0].tiffRepresentation == images[1].tiffRepresentation)
    }
  }

  @Test(arguments: [MenuBarStyle.ring, .pie, .history, .line, .meter, .dot])
  func graphicalStylesCenterTheirTwoLineText(style: MenuBarStyle) throws {
    var reading = MenuBarReading.sample
    reading.keepAwake = false
    reading.batteryCharging = false
    reading.bluetoothDevice = nil
    reading.aiQuotas = []
    for item: MenuBarItem in [.cpu, .battery, .aiUsage] {
      for valueOnTop in [false, true] {
        try expectCenteredTrailingText(
          reading: reading, item: item, style: style, valueOnTop: valueOnTop)
      }
    }
  }

  @Test(arguments: [MenuBarStyle.ring, .pie, .history, .line, .meter, .dot])
  func quotaGraphicalStylesCenterTheirTwoLineText(style: MenuBarStyle) throws {
    var reading = MenuBarReading.sample
    reading.keepAwake = false
    reading.aiQuotas = [
      MenuBarQuota(
        provider: .codex,
        window: AIQuotaWindow(kind: .weekly, usedPercent: 96, resetsAt: nil),
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), isStale: false)
    ]
    for valueOnTop in [false, true] {
      try expectCenteredTrailingText(
        reading: reading, item: .aiUsage, style: style, valueOnTop: valueOnTop)
    }
  }

  private func expectCenteredTrailingText(
    reading: MenuBarReading, item: MenuBarItem, style: MenuBarStyle, valueOnTop: Bool
  ) throws {
    let bitmaps = try [MenuBarStyle.stackedCenter, style].map { candidate in
      let image = MenuBarRenderer.image(
        reading: reading, items: [item], style: { _ in candidate },
        networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false, valueOnTop: valueOnTop)
      let preview = MenuBarRenderer.preview(image, dark: false, backingScale: 2)
      let data = try #require(preview.tiffRepresentation)
      return try #require(NSBitmapImageRep(data: data))
    }
    let reference = try #require(bitmaps[0].cgImage)
    let actual = try #require(bitmaps[1].cgImage)
    // 图形占据左侧；右侧文字应与独立“双行居中”逐像素一致，不能沿用靠右排版。
    let crop = try #require(
      actual.cropping(
        to: CGRect(
          x: actual.width - reference.width, y: 0,
          width: reference.width, height: reference.height)))
    let expected = NSBitmapImageRep(cgImage: reference).representation(using: .png, properties: [:])
    let result = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])
    #expect(result == expected, "\(item) 的 \(style) 文字应居中")
  }

  @Test(arguments: [false, true])
  func quotaIconsMatchServicesAndDirectAccounts(dark: Bool) throws {
    let providers = ["grok", "codex", "copilot", "claude", "gemini", "perplexity"]
    let fallback = try #require(
      quotaIconImage(providers: ["unknown"], dark: dark).tiffRepresentation)
    var rendered: Set<Data> = []
    for provider in providers {
      let data = try #require(quotaIconImage(providers: [provider], dark: dark).tiffRepresentation)
      // 同一百分比下各服务必须有独立标志，不能全部退回通用星形图标。
      #expect(data != fallback)
      #expect(rendered.insert(data).inserted)
      let bitmap = try #require(NSBitmapImageRep(data: data))
      var monochrome = true
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<min(28, bitmap.pixelsWide) {
          let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          if color.alphaComponent > 0.05 {
            monochrome =
              monochrome && abs(color.redComponent - color.greenComponent) < 0.01
              && abs(color.greenComponent - color.blueComponent) < 0.01
          }
        }
      }
      #expect(monochrome, "菜单栏标志不应残留 SVG 原色")
      if AIProviderID(rawValue: provider) != nil {
        let direct = try #require(
          quotaIconImage(providers: [provider], dark: dark, magpie: false).tiffRepresentation)
        #expect(direct == data)
      }
      let otherAppearance = try #require(
        quotaIconImage(providers: [provider], dark: !dark).tiffRepresentation)
      #expect(otherAppearance != data)
    }
    if let directory = ProcessInfo.processInfo.environment["XSTATS_MAGPIE_PREVIEW_DIR"] {
      // 使用截图中的短百分比验证实际观感，均为演示数据。
      let image = quotaIconImage(
        providers: ["codex", "grok", "claude"], dark: dark, remainingPercents: [16, 0, 0.5])
      let size = NSSize(width: image.size.width + 20, height: image.size.height + 20)
      let canvas = NSImage(size: size, flipped: false) { _ in
        NSColor(calibratedWhite: dark ? 0.12 : 0.96, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(at: NSPoint(x: 10, y: 10), from: .zero, operation: .sourceOver, fraction: 1)
        return true
      }
      let tiff = try #require(canvas.tiffRepresentation)
      let bitmap = try #require(NSBitmapImageRep(data: tiff))
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent(
            dark ? "magpie-menubar-spacing-dark.png" : "magpie-menubar-spacing-light.png"))
    }
  }

  @Test func shortQuotaValuesStayNearIconsWithoutResizing() throws {
    var widths: Set<CGFloat> = []
    for remaining in [0.0, 0.5, 4.0, 32.0, 99.0] {
      let image = quotaIconImage(providers: ["codex"], dark: false, remainingPercents: [remaining])
      widths.insert(image.size.width)
      let tiff = try #require(image.tiffRepresentation)
      let bitmap = try #require(NSBitmapImageRep(data: tiff))
      // 图标为 14pt，间隙为 3pt；短数值紧跟图标，不能靠右对齐到占位末端。
      var firstTextPixel: Int?
      for x in 28..<bitmap.pixelsWide {
        if (0..<bitmap.pixelsHigh).contains(where: {
          (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.1
        }) {
          firstTextPixel = x
          break
        }
      }
      let start = try #require(firstTextPixel)
      #expect((34...38).contains(start))
    }
    #expect(widths.count == 1)
    let ordinaryWidth = try #require(widths.first)
    let full = quotaIconImage(providers: ["codex"], dark: false, remainingPercents: [100])
    // 三位数及接近满额的 >99% 增加一位的空间，不能裁掉边界值。
    #expect(full.size.width > ordinaryWidth)
    #expect(full.size.width - ordinaryWidth <= 8)
    let nearlyFull = quotaIconImage(providers: ["codex"], dark: false, remainingPercents: [99.5])
    #expect(nearlyFull.size.width == full.size.width)
    let compact = quotaIconImage(
      providers: ["codex", "grok", "claude"], dark: false,
      remainingPercents: [16, 0, 0.5])
    #expect(compact.size.width <= 145)
  }

  @Test(arguments: MenuBarStyle.options(for: .aiUsage))
  func quotaServiceGroupsIgnoreOuterItemSpacing(style: MenuBarStyle) {
    for providers in [["codex"], ["codex", "claude"], ["codex", "claude", "grok", "gemini"]] {
      let compact = quotaIconImage(providers: providers, dark: false, style: style, itemGap: 4)
      for gap: CGFloat in [6, 8, 12] {
        let expanded = quotaIconImage(providers: providers, dark: false, style: style, itemGap: gap)
        #expect(expanded.size.width == compact.size.width)
      }
    }
  }

  private func quotaIconImage(
    providers: [String], dark: Bool, magpie: Bool = true,
    remainingPercents: [Double] = [], style: MenuBarStyle = .icon, itemGap: CGFloat = 8
  ) -> NSImage {
    var reading = MenuBarReading.sample
    reading.keepAwake = false
    reading.aiQuotas = providers.enumerated().map { index, provider in
      let remaining = remainingPercents.indices.contains(index) ? remainingPercents[index] : 68
      return MenuBarQuota(
        provider: AIProviderID(rawValue: provider),
        window: AIQuotaWindow(kind: .weekly, usedPercent: 100 - remaining, resetsAt: nil),
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), isStale: false,
        magpieName: magpie ? provider : nil)
    }
    let image = MenuBarRenderer.image(
      reading: reading, items: [.aiUsage], style: { _ in style },
      networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false, itemGap: itemGap)
    return MenuBarRenderer.preview(image, dark: dark, backingScale: 2)
  }

  @Test func batteryPreviewIgnoresCPUAndStillObservesBattery() async throws {
    let suite = "MenuBarReadingTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      aiUsageProviders: [], aiQuotaProviders: [])
    await confirmation(expectedCount: 0) { changed in
      withObservationTracking {
        _ = MenuBarReading(model: model, items: [.battery])
      } onChange: {
        changed()
      }
      var snapshot = MetricsSnapshot()
      snapshot.cpu = CPULoad(
        total: 0.5, user: 0.3, system: 0.2, perCore: [0.5], loadAverage: [1, 1, 1])
      model.store.apply(snapshot)
    }
    await confirmation(expectedCount: 1) { changed in
      withObservationTracking {
        _ = MenuBarReading(model: model, items: [.battery])
      } onChange: {
        changed()
      }
      var snapshot = MetricsSnapshot()
      snapshot.battery = BatteryStatus(
        level: 0.75, isCharging: true, isPluggedIn: true,
        isFullyCharged: false, minutesRemaining: 20, cycleCount: 30,
        health: 0.98, adapterWatts: 60)
      model.store.apply(snapshot)
    }
  }

  @Test func scopedReadingsPreserveEveryItemImage() throws {
    let suite = "MenuBarReadingTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
      settings: AppSettings(defaults: defaults), historyURL: nil,
      aiUsageProviders: [], aiQuotaProviders: [])
    var snapshot = MetricsSnapshot()
    snapshot.cpu = CPULoad(
      total: 0.83, user: 0.6, system: 0.23, perCore: [0.83], loadAverage: [1, 1, 1])
    snapshot.gpu = GPUUsage(name: "Fixture", utilization: 0.3, coreCount: 8)
    snapshot.memory = MemoryUsage(
      total: 1_000, app: 300, wired: 100, compressed: 50, cached: 200,
      swapUsed: 0, swapTotal: 0, pressure: .normal, uncompressed: 100,
      swapInBytes: 0, swapOutBytes: 0)
    snapshot.sensors = SensorReadings(
      temperatures: [
        TemperatureSummary(
          group: .cpu, average: 50,
          maximum: 60, sensorCount: 4)
      ],
      fans: [
        FanState(
          id: 0, current: 1_800, minimum: 0, maximum: 6_000,
          target: 1_800, isManual: false)
      ], fanCount: 1)
    snapshot.disk = DiskUsage(volumeName: "Fixture", total: 1_000, available: 350)
    snapshot.network = NetworkRate(
      downloadBytesPerSecond: 1_500_000, uploadBytesPerSecond: 20_000,
      totalDownloaded: 10_000_000, totalUploaded: 100_000)
    snapshot.battery = BatteryStatus(
      level: 0.15, isCharging: true, isPluggedIn: true,
      isFullyCharged: false, minutesRemaining: 20, cycleCount: 30,
      health: 0.98, adapterWatts: 60)
    model.store.apply(snapshot)
    for item in MenuBarItem.allCases {
      let complete = MenuBarReading(model: model)
      let scoped = MenuBarReading(model: model, items: [item])
      #expect(
        scoped.tooltip(items: [item], fahrenheit: false)
          == complete.tooltip(items: [item], fahrenheit: false))
      for style in MenuBarStyle.options(for: item) {
        #expect(scoped.hasSameImage(as: complete, item: item, style: style))
        let completeImage = MenuBarRenderer.image(
          reading: complete, items: [item], style: { _ in style },
          networkStyle: .dots, colorizeHighLoad: true, fahrenheit: false)
        let scopedImage = MenuBarRenderer.image(
          reading: scoped, items: [item], style: { _ in style },
          networkStyle: .dots, colorizeHighLoad: true, fahrenheit: false)
        for dark in [false, true] {
          let before = try #require(
            MenuBarRenderer.preview(completeImage, dark: dark).tiffRepresentation)
          let after = try #require(
            MenuBarRenderer.preview(scopedImage, dark: dark).tiffRepresentation)
          #expect(before == after)
        }
      }
    }
  }
}
