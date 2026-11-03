// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct DesignAccessibilityTests {
  @Test(arguments: [false, true])
  func supportingTextRemainsReadableOnWindowAndCards(dark: Bool) throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    for text in [DS.Palette.textSecondary, DS.Palette.textTertiary] {
      for background in [DS.Palette.background, DS.Palette.surface, DS.Palette.elevated] {
        #expect(try contrast(text, on: background, appearance: appearance) >= 4.5)
      }
    }
  }

  @Test(arguments: [false, true])
  func primaryActionsKeepReadableTextInBothAppearances(dark: Bool) throws {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    for background in [DS.Palette.primaryAction, DS.Palette.primaryActionHover] {
      #expect(try contrast(DS.Palette.onPrimary, on: background, appearance: appearance) >= 4.5)
    }
  }

  @Test(arguments: [640.0, 1600.0], [false, true])
  func designControlsFitNarrowAndWideWindows(width: Double, dark: Bool) throws {
    for language in [AppLanguage.chinese, .german, .arabic] {
      let direction: LayoutDirection = language.isRightToLeft ? .rightToLeft : .leftToRight
      let start = Date(timeIntervalSince1970: 1_800_000_000)
      let points: [HistoryPoint] = (0..<20).map { index -> HistoryPoint in
        let average: Double? = index == 10 ? nil : Double(index % 5) / 10
        let maximum: Double? = index == 10 ? nil : Double(index % 5 + 3) / 10
        return HistoryPoint(
          date: start.addingTimeInterval(Double(index) * 60),
          cpu: average, cpuMax: maximum)
      }
      let view = PageScroll(contentMaxWidth: DS.Size.settingsContentWidth) {
        SettingsGroup {
          GroupRow(showsDivider: false) {
            SettingRow(
              title: L10n.translate("刷新频率", language: language),
              subtitle: L10n.translate(
                "只显示菜单栏时的采样间隔；打开弹窗或主窗口时为 1 秒（进程页 2 秒）", language: language)
            ) {
              SegmentedControl(
                selection: .constant(1), options: [(1, "1"), (2, "2"), (3, "3")]
              )
              .frame(width: 160)
            }
          }
          GroupRow {
            SettingRow(title: L10n.translate("XStats 辅助工具", language: language)) {
              Button(L10n.translate("安装辅助工具", language: language)) {}
                .buttonStyle(DSButtonStyle(kind: .primary))
            }
          }
          GroupRow {
            SettingRow(title: L10n.translate("正在启用…", language: language)) {
              Button(L10n.translate("安装辅助工具", language: language)) {}
                .buttonStyle(DSButtonStyle(kind: .primary))
                .disabled(true)
            }
          }
        }
        HistoryChartCard(
          icon: "cpu", title: "CPU", points: points, start: start,
          end: start.addingTimeInterval(1200), hoverDate: .constant(nil),
          series: [
            .init(
              label: L10n.translate("平均", language: language),
              color: DS.Palette.primary, value: \.cpu),
            .init(
              label: L10n.translate("峰值", language: language),
              color: DS.Palette.primarySoft, value: \.cpuMax, filled: false),
          ], maxValue: 1,
          format: {
            $0.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale(for: language)))
          }, language: language)
      }
      .environment(\.isSnapshot, true)
      .environment(\.layoutDirection, direction)
      .environment(\.locale, L10n.locale(for: language))
      .environment(\.colorScheme, dark ? .dark : .light)
      .background(DS.Palette.background)
      .frame(width: width)
      let host = NSHostingView(rootView: view)
      let size = host.fittingSize
      #expect(size.width == width && size.height > 200 && size.height < 900)
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.contentView = host
      defer {
        window.contentView = nil
        window.close()
      }
      host.layoutSubtreeIfNeeded()
      if let path = ProcessInfo.processInfo.environment["XSTATS_DESIGN_PREVIEW_DIR"] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: folder.appendingPathComponent(
            "design-\(language.languageCode)-\(Int(width))-\(dark ? "dark" : "light").png"))
      }
    }
  }

  private func contrast(_ foreground: Color, on background: Color, appearance: NSAppearance) throws
    -> Double
  {
    let a = try luminance(foreground, appearance: appearance)
    let b = try luminance(background, appearance: appearance)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  private func luminance(_ color: Color, appearance: NSAppearance) throws -> Double {
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolved = NSColor(color).usingColorSpace(.sRGB)
    }
    let rgb = try #require(resolved)
    let components: [Double] = [
      Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent),
    ]
    let values: [Double] = components.map { value in
      if value <= 0.04045 { return value / 12.92 }
      return pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
  }
}

@MainActor
@Observable
private final class SelectionFixture {
  var value = 0
}

@MainActor
private final class SelectionTransactions {
  var values: [(value: Int, animated: Bool)] = []
}

private struct SelectionTransactionProbe: NSViewRepresentable {
  let value: Int
  let transactions: SelectionTransactions

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    transactions.values.append(
      (value, context.transaction.animation != nil && !context.transaction.disablesAnimations))
  }
}

private struct SelectionFixtureView: View {
  let model: SelectionFixture
  let transactions: SelectionTransactions

  var body: some View {
    SelectionTransactionProbe(value: model.value, transactions: transactions)
      .frame(width: 160, height: 40)
      .dsSelectionAnimation(DS.Motion.quick, value: model.value)
  }
}

@MainActor
struct DesignSelectionMotionTests {
  @Test(arguments: [NSEvent.EventType?.some(.leftMouseUp), .some(.keyDown), .some(.keyUp), .none])
  func selectionTransactionsRespectInputAndAccessibility(event: NSEvent.EventType?) async throws {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let model = SelectionFixture()
    let transactions = SelectionTransactions()
    let hosting = NSHostingView(
      rootView: SelectionFixtureView(model: model, transactions: transactions))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(40))
    DS.Motion.select(event: event) { model.value = 1 }
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(40))
    let selected = try #require(transactions.values.last(where: { $0.value == 1 }))
    #expect(selected.animated == (!reduceMotion && event == .leftMouseUp))
    #expect(model.value == 1)
  }
}
