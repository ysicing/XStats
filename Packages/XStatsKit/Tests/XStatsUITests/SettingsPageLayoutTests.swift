// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct SettingsPageLayoutTests {
  @Test(
    arguments: [
      PanelTab.settingsGeneral, .settingsFeatures, .audio, .cpu, .gpu, .memory, .network,
    ], [840.0, 1753.0])
  func pagesRenderInMainWindow(page: PanelTab, width: Double) throws {
    _ = NSApplication.shared
    let suite = "SettingsMainWindowLayout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules =
      page == .settingsGeneral || page == .settingsFeatures ? [] : Set(MonitoringModule.allCases)
    settings.audioEnabled = page == .audio
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.panelTab = page
    #expect(settings.panelTab == page)
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient(),
      networkCacheDefaults: defaults)
    let host = NSHostingView(
      rootView: MainWindowView().environment(model).environment(\.colorScheme, .light)
        .frame(width: width, height: 1160))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 1160),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    #expect(settings.panelTab == page)
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    if let path = ProcessInfo.processInfo.environment["XSTATS_SETTINGS_PREVIEW_DIR"] {
      let folder = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: folder.appendingPathComponent("main-\(page.rawValue)-\(Int(width)).png"))
    }
  }

  @Test(arguments: [640.0, 900.0, 1553.0], [false, true])
  func settingsFillContentArea(width: Double, snapshot: Bool) throws {
    _ = NSApplication.shared
    let suite = "SettingsPageLayout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = []
    settings.menuBarItems = []
    settings.historyEnabled = false
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())

    for language in [AppLanguage.chinese, .english, .german, .arabic] {
      let probe = NSView()
      let view = SettingsTabPage {
        SettingsGroup {
          GroupRow(showsDivider: false) {
            SettingRow(
              title: L10n.translate("外观", language: language),
              subtitle: L10n.translate("主窗口与弹窗的配色；菜单栏始终跟随系统", language: language)
            ) {
              SegmentedControl(
                selection: .constant(1),
                options: [
                  (0, L10n.translate("跟随系统", language: language)),
                  (1, L10n.translate("浅色", language: language)),
                  (2, L10n.translate("深色", language: language)),
                ]
              )
              .frame(width: DS.Size.sidebarWidth + DS.Space.s12)
            }
          }
          GroupRow {
            let title = L10n.translate("关窗后保留程序坞图标", language: language)
            SettingRow(
              title: title,
              subtitle: L10n.translate("打开窗口时自动显示图标；关闭后仍可从程序坞与 ⌘Tab 找到 XStats", language: language)
            ) {
              DSToggle(isOn: .constant(false), label: title)
            }
          }
        }
        .background { SettingsWidthProbe(view: probe) }
      }
      .environment(model)
      .environment(\.isSnapshot, snapshot)
      .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
      .environment(\.locale, L10n.locale(for: language))
      .environment(\.colorScheme, .light)
      .frame(width: width, height: 300, alignment: .top)
      .background(DS.Palette.background)
      let host = NSHostingView(rootView: view)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: .aqua)
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
      if let path = ProcessInfo.processInfo.environment["XSTATS_SETTINGS_PREVIEW_DIR"] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: folder.appendingPathComponent(
            "settings-\(language.languageCode)-\(Int(width))-\(snapshot ? "snapshot" : "scroll").png"
          ))
      }
    }
  }
}

private struct SettingsWidthProbe: NSViewRepresentable {
  let view: NSView

  func makeNSView(context: Context) -> NSView { view }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
