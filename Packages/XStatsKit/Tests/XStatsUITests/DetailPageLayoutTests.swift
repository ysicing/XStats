// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct DetailPageLayoutTests {
  @Test(arguments: [640.0, 900.0, 1561.0], [false, true])
  func detailsFillContentArea(width: Double, snapshot: Bool) {
    _ = NSApplication.shared
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let probe = NSView()
      let host = NSHostingView(
        rootView: DetailPage {
          Color.clear.frame(height: 100)
            .background { DetailWidthProbe(view: probe) }
        }
        .environment(\.isSnapshot, snapshot)
        .environment(\.layoutDirection, direction)
        .frame(width: width, height: 300))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      defer {
        window.contentView = nil
        window.close()
      }
      host.layoutSubtreeIfNeeded()
      let bounds = probe.convert(probe.bounds, to: host)
      #expect(abs(bounds.width - (width - 2 * DS.Space.s3)) < 1)
      #expect(abs(bounds.minX - DS.Space.s3) < 1)
      #expect(abs(bounds.maxX - (width - DS.Space.s3)) < 1)
    }
  }

  @Test(arguments: [640.0, 1561.0], [false, true])
  func networkHeaderRendersInBothLayoutDirections(width: Double, showsPorts: Bool) throws {
    _ = NSApplication.shared
    let suite = "NetworkHeaderLayout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = Set(MonitoringModule.allCases)
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.portsEnabled = showsPorts
    settings.portsPlacement = .network
    settings.panelTab = .network
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient(),
      networkCacheDefaults: defaults)
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let host = NSHostingView(
        rootView: PageHeader(cleanerTab: .constant(.clean))
          .environment(model)
          .environment(\.layoutDirection, direction)
          .environment(\.colorScheme, .light)
          .frame(width: width, height: DS.Size.windowHeader)
          .background(DS.Palette.background))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: DS.Size.windowHeader),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      defer {
        window.contentView = nil
        window.close()
      }
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
      if let path = ProcessInfo.processInfo.environment["XSTATS_SETTINGS_PREVIEW_DIR"] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: folder.appendingPathComponent(
            "network-header-\(Int(width))-\(showsPorts ? "ports" : "no-ports")-\(direction == .rightToLeft ? "rtl" : "ltr").png"
          ))
      }
    }
  }
}

private struct DetailWidthProbe: NSViewRepresentable {
  let view: NSView

  func makeNSView(context: Context) -> NSView { view }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
