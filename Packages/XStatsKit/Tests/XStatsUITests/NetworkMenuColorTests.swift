// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct NetworkMenuColorTests {
  @Test func preferencesPersistAndBackupsDistinguishResetFromMissingField() throws {
    let suite = "NetworkMenuColors.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let original = NetworkMenuColors()
    #expect(settings.networkMenuColors == original)
    let custom = NetworkMenuColors(upload: 0xFF8800, download: 0xCC22EE)
    settings.networkMenuColors = custom
    #expect(AppSettings(defaults: defaults).networkMenuColors == custom)
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(settings.networkMenuColors == custom)
    let backup = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    settings.networkMenuColors = original
    settings.apply(backup)
    #expect(settings.networkMenuColors == custom)
    settings.networkMenuColors = original
    let reset = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    settings.networkMenuColors = custom
    settings.apply(reset)
    #expect(AppSettings(defaults: defaults).networkMenuColors == original)

    var invalid = SettingsDocument()
    invalid.networkMenuColors = NetworkMenuColors(upload: 0x1000000, download: 0xFFFFFF)
    settings.apply(invalid)
    #expect(settings.networkMenuColors == NetworkMenuColors(download: 0xFFFFFF))
    settings.networkMenuColors = NetworkMenuColors(upload: .max, download: 0)
    #expect(settings.networkMenuColors == NetworkMenuColors(download: 0))
    defaults.set(Data("invalid".utf8), forKey: "networkMenuColors")
    #expect(AppSettings(defaults: defaults).networkMenuColors == original)
    defaults.set(
      try JSONEncoder().encode(NetworkMenuColors(upload: .max, download: 0)),
      forKey: "networkMenuColors")
    #expect(AppSettings(defaults: defaults).networkMenuColors == NetworkMenuColors(download: 0))
    #expect(
      NetworkMenuColors.rgb(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.1)) == 0xFF8000)
  }

  @Test(arguments: [false, true])
  func dotsUseIndependentColorsAndResetKeepsDynamicDefaults(dark: Bool) throws {
    let custom = NetworkMenuColors(upload: 0xFF8800, download: 0xCC22EE)
    for colors in [NetworkMenuColors(), custom, NetworkMenuColors(download: 0xCC22EE)] {
      let image = render(colors: colors, style: .dots)
      #expect(!image.isTemplate)
      let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
      let bitmap = try raster(image, appearance: appearance)
      for (upper, expected) in [(true, colors.uploadColor), (false, colors.downloadColor)] {
        var target: NSColor?
        appearance.performAsCurrentDrawingAppearance {
          target = expected.usingColorSpace(.deviceRGB)
        }
        let color = try #require(target)
        var matches = 0
        let rows = upper ? 0..<(bitmap.pixelsHigh / 2) : (bitmap.pixelsHigh / 2)..<bitmap.pixelsHigh
        for y in rows {
          for x in 0..<10 {
            guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
              pixel.alphaComponent > 0.95
            else { continue }
            if abs(pixel.redComponent - color.redComponent) < 0.02
              && abs(pixel.greenComponent - color.greenComponent) < 0.02
              && abs(pixel.blueComponent - color.blueComponent) < 0.02
            {
              matches += 1
            }
          }
        }
        #expect(matches > 10, "dark=\(dark), upload=\(upper), \(colors)")
      }
    }
    for style: NetworkMenuStyle in [.arrows, .inline] {
      let original = render(colors: NetworkMenuColors(), style: style)
      let changed = render(colors: custom, style: style)
      #expect(original.isTemplate && changed.isTemplate)
      let first = MenuBarRenderer.preview(original, dark: dark, backingScale: 2)
      let second = MenuBarRenderer.preview(changed, dark: dark, backingScale: 2)
      #expect(first.tiffRepresentation == second.tiffRepresentation)
    }
  }

  @Test func settingsRefreshMenuImageWithoutWaitingForNewReadings() throws {
    _ = NSApplication.shared
    let suite = "NetworkMenuColors.Refresh.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarLayout = .combined
    settings.menuBarItems = [.network]
    settings.historyEnabled = false
    settings.enabledAlerts = []
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    let controller = MenuBarController(model: model)
    defer { controller.dismissPopovers() }
    controller.update()
    let button = try #require(controller.combinedButton)
    let original = try #require(button.image)
    let reading = MenuBarReading(model: model, items: [.network])
    settings.networkMenuColors = NetworkMenuColors(upload: 0xFF8800, download: 0xCC22EE)
    controller.update()
    let changed = try #require(button.image)
    #expect(
      reading.hasSameImage(
        as: MenuBarReading(model: model, items: [.network]), item: .network,
        style: settings.style(for: .network)))
    let appearance = try #require(NSAppearance(named: .aqua))
    #expect(
      try raster(original, appearance: appearance).tiffRepresentation
        != raster(changed, appearance: appearance).tiffRepresentation)
    controller.refreshImages()
    #expect(button.image === changed)
    settings.networkMenuColors = NetworkMenuColors()
    controller.update()
    let restored = try #require(button.image)
    #expect(
      try raster(original, appearance: appearance).tiffRepresentation
        == raster(restored, appearance: appearance).tiffRepresentation)
  }

  @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
  func nativeControlsFitLongLabelsAndRightToLeft(language: AppLanguage) throws {
    _ = NSApplication.shared
    let host = NSHostingView(
      rootView: NetworkMenuColorControls(
        colors: .constant(NetworkMenuColors(upload: 0xFF8800, download: 0xCC22EE)),
        uploadTitle: L10n.translate("上传", language: language),
        downloadTitle: L10n.translate("下载", language: language),
        resetTitle: L10n.translate("恢复默认", language: language)
      )
      .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
      .padding(12)
      .frame(width: 280)
      .background(DS.Palette.background))
    let size = host.fittingSize
    #expect(size.width == 280 && size.height > 35 && size.height < 125)
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
    if let path = ProcessInfo.processInfo.environment["XSTATS_NETWORK_COLORS_PREVIEW_DIR"] {
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: path).appendingPathComponent("\(language.rawValue).png"))
    }
  }

  private func render(colors: NetworkMenuColors, style: NetworkMenuStyle) -> NSImage {
    MenuBarRenderer.image(
      reading: .sample, items: [.network], style: { _ in .stacked },
      networkStyle: style, networkColors: colors, colorizeHighLoad: false, fahrenheit: false)
  }

  /// 在固定色彩空间直接绘制，避免 TIFF/HDR 元数据改变回读颜色。
  private func raster(_ image: NSImage, appearance: NSAppearance) throws -> NSBitmapImageRep {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2),
        pixelsHigh: Int(image.size.height * 2), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = image.size
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    appearance.performAsCurrentDrawingAppearance {
      image.draw(in: NSRect(origin: .zero, size: image.size))
    }
    return bitmap
  }
}
