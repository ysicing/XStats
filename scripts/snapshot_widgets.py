#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

"""用当前 Widget 视图和隔离演示数据生成 README 截图，不读写 App Group。"""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
HARNESS = r"""
@main
struct WidgetGallery {
  @MainActor
  static func main() throws {
    _ = NSApplication.shared
    L10n.configure(.chinese)
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let day = CalendarEngine.day(year: 2026, month: 9, day: 23)!
    let tomorrow = CalendarEngine.day(year: 2026, month: 9, day: 24)!
    let features = CalendarFeature.mainlandChinaDefaults
    let calendar = CalendarWidgetEntry(
      date: day.date, showsLunar: true, showsSeasonal: true, firstWeekday: 2,
      today: CalendarEngine.widgetSummary(for: day, features: features),
      tomorrow: CalendarEngine.widgetSummary(for: tomorrow, features: features),
      month: CalendarEngine.widgetMonthSummary(
        year: 2026, month: 9, firstWeekday: 2, features: features))
    let providers = ["claude", "codex", "grok", "workbuddy"]
    let quotas = zip(providers, [72.0, 61, 38, 89]).enumerated().map { index, item in
      WidgetSnapshot.Quota(
        provider: item.0, kind: "weekly", remainingPercent: item.1,
        resetsAt: day.date.addingTimeInterval(Double(index + 1) * 86400),
        fetchedAt: day.date, isStale: false)
    }
    let snapshot = WidgetSnapshot(
      aiEnabled: true, quotas: quotas,
      dailyTokens: [.init(provider: "Magpie", day: day.date, tokens: 428_600)],
      cumulativeTokens: [
        .init(provider: "Magpie", input: 18_400_000, output: 3_200_000, scope: .all)
      ], quotaProviders: providers, language: AppLanguage.chinese.rawValue)
    var doubleSnapshot = snapshot
    doubleSnapshot.quotaShowsResetRing = true
    let single = SharedDataEntry(date: day.date, snapshot: snapshot)
    let double = SharedDataEntry(date: day.date, snapshot: doubleSnapshot)
    for dark in [false, true] {
      NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      let suffix = dark ? "dark" : "light"
      let gallery = VStack(spacing: 16) {
        HStack(spacing: 16) {
          card(AIQuotaWidgetView(family: .systemMedium, entry: single), width: 344, height: 164)
          card(AIQuotaWidgetView(family: .systemMedium, entry: double), width: 344, height: 164)
        }
        HStack(alignment: .top, spacing: 16) {
          card(MonthCalendarWidgetView(entry: calendar), width: 344, height: 344, inset: 0)
          VStack(spacing: 16) {
            HStack(spacing: 16) {
              card(AIQuotaWidgetView(family: .systemSmall, entry: double), width: 164, height: 164)
              card(CalendarWidgetView(family: .systemSmall, entry: calendar),
                width: 164, height: 164, inset: 0)
            }
            card(TodayTokensWidgetView(family: .systemMedium, entry: single),
              width: 344, height: 164)
          }
        }
      }
      .padding(24)
      .background(dark ? Color(white: 0.06) : Color(white: 0.94))
      try write(gallery, dark: dark, to: output.appendingPathComponent("widgets-\(suffix).png"))
      try write(
        card(TomorrowWorkWidgetView(entry: calendar), width: 164, height: 164, inset: 0),
        dark: dark, to: output.appendingPathComponent("widget-tomorrow-\(suffix).png"))
    }
  }

  @MainActor
  static func card<V: View>(_ view: V, width: CGFloat, height: CGFloat, inset: CGFloat = 16)
    -> some View
  {
    view.padding(inset).frame(width: width, height: height)
      .background(Color(nsColor: .windowBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 22))
  }

  @MainActor
  static func write<V: View>(_ view: V, dark: Bool, to url: URL) throws {
    let content = view
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.locale, L10n.locale)
      .environment(\.layoutDirection, .leftToRight)
    let host = NSHostingView(rootView: content)
    host.appearance = NSApp.appearance
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(
      contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw CocoaError(.coderInvalidValue)
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.coderInvalidValue)
    }
    try data.write(to: url)
  }
}
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    products = ROOT / "Packages/XStatsKit/.build/debug"
    objects = [products / f"{name}.o" for name in ("Localization", "WidgetData", "Tyme4Swift")]
    bundle = products / "XStatsKit_Localization.bundle"
    if not all(path.exists() for path in [*objects, bundle]):
        parser.error("先执行 swift build --package-path Packages/XStatsKit --jobs 2 --target XStatsUI")
    # 只将 WidgetKit 容器改为截图画布，并显式注入 family；业务布局仍取自当前源码。
    sources = []
    for name in ("SharedDataWidgets.swift", "CalendarWidget.swift"):
        text = (ROOT / "Apps/XStats/Widget" / name).read_text()
        text = text.replace(
            r"@Environment(\.widgetFamily) private var family",
            "var family: WidgetFamily = .systemMedium",
        )
        marker = ".containerBackground(.background, for: .widget)"
        if marker not in text:
            raise RuntimeError(f"{name} 的容器发生变化，请核对截图适配")
        sources.append(text.replace(marker, ""))
    with tempfile.TemporaryDirectory(prefix="xstats-widget-gallery-") as folder:
        temporary = Path(folder)
        app = temporary / "WidgetGallery.app"
        executable = app / "Contents/MacOS/WidgetGallery"
        resources = app / "Contents/Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir(parents=True)
        shutil.copytree(bundle, resources / bundle.name)
        for logo in (ROOT / "Packages/XStatsKit/Sources/XStatsUI/Resources/Logos").glob("*.svg"):
            shutil.copy2(logo, resources / logo.name)
        source = temporary / "Gallery.swift"
        source.write_text("\n".join(sources) + HARNESS)
        ui = ROOT / "Packages/XStatsKit/Sources/XStatsUI"
        subprocess.run(
            [
                "swiftc", "-j2", "-swift-version", "6", "-parse-as-library",
                "-I", str(products), str(source),
                str(ui / "Design/AIServiceBrand.swift"),
                str(ui / "Calendar/CalendarEngine.swift"),
                str(ui / "Calendar/CalendarAlmanac.swift"),
                *map(str, objects), "-o", str(executable),
            ],
            check=True,
        )
        subprocess.run([str(executable), str(args.output.resolve())], check=True)


if __name__ == "__main__":
    main()
