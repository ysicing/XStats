// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct KeepAwakeSettingsLayoutTests {
  @Test func batterySettingsAndLongToggleLabelsFitInBothDirections() throws {
    _ = NSApplication.shared
    let suite = "KeepAwakeSettingsLayout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = []
    settings.menuBarItems = []
    settings.combinedOverviewItems = []
    settings.historyEnabled = false
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    var views = [AnyView(LidBatterySettings().environment(model))]
    // 显式译文验证长标题和 RTL，不切换进程全局语言。
    for language in [AppLanguage.english, .german, .french, .arabic] {
      let title = L10n.translate("低电量时停止防休眠", language: language)
      views.append(
        AnyView(
          SettingRow(title: title) {
            DSToggle(isOn: .constant(false), label: title)
          }
          .padding(DS.Space.s4)))
    }
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      for (index, view) in views.enumerated() {
        let host = NSHostingView(
          rootView: view.environment(\.layoutDirection, direction)
            .frame(width: DS.Size.panelWidth))
        let size = host.fittingSize
        #expect(abs(size.width - DS.Size.panelWidth) < 1)
        try #require(size.height.isFinite && size.height > 0 && size.height < 300)
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let path = ProcessInfo.processInfo.environment["XSTATS_KEEP_AWAKE_PREVIEW_DIR"] {
          let directory = URL(fileURLWithPath: path, isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          let name = "\(index)-\(direction == .leftToRight ? "ltr" : "rtl").png"
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: directory.appendingPathComponent(name))
        }
      }
    }
    #expect(!settings.keepAwakeStopOnLowBattery && !model.demand.hasSamples)
  }
}
