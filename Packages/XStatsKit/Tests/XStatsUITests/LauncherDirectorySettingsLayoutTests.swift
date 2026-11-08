// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct LauncherDirectorySettingsLayoutTests {
  @Test(arguments: [AppLanguage.german, .arabic], [0, 16])
  func directorySettingsRenderWithIsolatedPreferences(
    language: AppLanguage, directoryCount: Int
  ) throws {
    _ = NSApplication.shared
    let suite = "LauncherDirectorySettingsLayout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directories = (0..<directoryCount).map { index in
      LauncherApplicationDirectories.Directory(
        id: UUID(),
        path:
          "/Volumes/Launcher Preview/Applications/Long folder name for desktop applications/Directory \(index)",
        bookmark: Data([1]))
    }
    defaults.set(
      try JSONEncoder().encode(directories),
      forKey: LauncherApplicationDirectories.defaultsKey)
    let center = NotificationCenter()
    let store = LauncherApplicationDirectories(defaults: defaults, notificationCenter: center)
    let probe = NSView()
    let view = ScrollView {
      LauncherDirectorySettings(store: store, language: language)
        .background { LauncherDirectoryLayoutProbe(view: probe) }
        .padding(DS.Space.s4)
    }
    .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
    .environment(\.locale, L10n.locale(for: language))
    .environment(\.colorScheme, .light)
    .frame(width: 480, height: 400)
    .background(DS.Palette.background)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    // 先保存原生渲染，再断言布局，失败场景也保留可供人工检查的截图。
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let path = ProcessInfo.processInfo.environment["XSTATS_LAUNCHPAD_PREVIEW_DIR"] {
      let folder = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: folder.appendingPathComponent(
          "launcher-directories-\(language.languageCode)-\(directoryCount).png"))
    }
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    let bounds = probe.convert(probe.bounds, to: host)
    let availableWidth = host.bounds.width - 2 * DS.Space.s4
    // 空态按内容决定宽度；空态和长列表均须落在视口内侧的水平留白之间。
    #expect(bounds.width > 0 && bounds.width <= availableWidth + 1)
    #expect(bounds.minX >= DS.Space.s4 - 1)
    #expect(bounds.maxX <= host.bounds.maxX - DS.Space.s4 + 1)
    #expect(bounds.height > 0)
    if directoryCount == 0 {
      #expect(bounds.height <= host.bounds.height - 2 * DS.Space.s4 + 1)
    } else {
      #expect(bounds.height > host.bounds.height)
    }
    #expect(store.directories == directories)
  }
}

private struct LauncherDirectoryLayoutProbe: NSViewRepresentable {
  let view: NSView

  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
