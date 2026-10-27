// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct PopoverSectionPresentationTests {
  @Test func compactEditorFitsNarrowAndWideSettingsInBothDirections() throws {
    let suite = "PopoverSectionPresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = []
    settings.menuBarItems = []
    settings.historyEnabled = false
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    for dark in [false, true] {
      for rtl in [false, true] {
        for width: CGFloat in [320, 800] {
          var collapsedHeight: CGFloat = 0
          for expanded in [false, true] {
            let host = NSHostingView(
              rootView: PopoverSectionPicker(isExpanded: expanded, item: .cpu)
                .environment(model)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .preferredColorScheme(dark ? .dark : .light)
                .frame(width: width, alignment: .leading)
                .padding(.vertical, DS.Space.s3)
                .background(DS.Palette.surface))
            let size = host.fittingSize
            #expect(abs(size.width - width) < 1 && size.height > 0 && size.height < 400)
            if expanded {
              #expect(size.height > collapsedHeight + 100)
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
            if let path = ProcessInfo.processInfo.environment["XSTATS_SETTINGS_PREVIEW_DIR"] {
              let directory = URL(fileURLWithPath: path, isDirectory: true)
              try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
              let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
              host.cacheDisplay(in: host.bounds, to: bitmap)
              let name = "cpu-\(Int(width))-\(dark)-\(rtl)-\(expanded).png"
              try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent(name))
            }
            window.close()
          }
        }
      }
    }
    #expect(settings.enabledMonitoringModules.isEmpty && !model.demand.hasSamples)
  }
}
