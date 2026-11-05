// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Localization
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct HomebrewImpactPresentationTests {
  @Test(arguments: [AppLanguage.chinese, .german, .arabic], [false, true])
  func impactAndEvidenceFitLongTextAndRTL(language: AppLanguage, dark: Bool) throws {
    _ = NSApplication.shared
    let package = try #require(
      HomebrewManagement.parse(
        #"{"formulae":[{"name":"developer-tool","full_name":"vendor/development/developer-tool","installed":[{"version":"1.0.0"}],"outdated":true,"versions":{"stable":"2.0.0"}}],"casks":[]}"#,
        prefix: URL(fileURLWithPath: "/opt/homebrew")
      ).first)
    let preview = HomebrewImpactPreview(
      package: package, action: .uninstall, output: "",
      dependents: ["vendor/development/editor", "another-development-tool"])
    let cask = try #require(
      HomebrewManagement.parse(
        #"{"formulae":[],"casks":[{"full_token":"vendor/apps/editor","installed":"1","artifacts":[{"app":["Example Editor.app"]}],"depends_on":null}]}"#,
        prefix: URL(fileURLWithPath: "/opt/homebrew")
      ).first)
    let content = VStack(alignment: .leading, spacing: 16) {
      HomebrewImpactView(
        preview: HomebrewImpactPreview(
          package: package, action: .upgrade,
          output:
            "==> Would upgrade 1 outdated package:\nvendor/development/developer-tool 1.0.0 -> 2.0.0\n==> Would install 1 dependency:\nlib-example 3.2.0"
        ),
        language: language
      ).padding(24).frame(width: 520)
      Divider()
      HomebrewImpactView(preview: preview, language: language).padding(24).frame(width: 520)
      Divider()
      InstallationSourceView(
        evidence: .homebrew(cask, URL(fileURLWithPath: "/Applications/Example Editor.app")),
        language: language)
      InstallationSourceView(evidence: .cachedHomebrew, language: language)
      InstallationSourceView(evidence: .xstats("work.12306.xstats.app"), language: language)
      InstallationSourceButton(label: "-", evidence: .unknown)
    }
    .frame(width: 520)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.colorScheme, dark ? .dark : .light)
    let host = NSHostingView(rootView: content)
    let size = host.fittingSize
    #expect(size.width <= 520 && size.height < 1200)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()
    let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    #expect(image.pixelsWide > 0 && image.pixelsHigh > 0)
    if let path = ProcessInfo.processInfo.environment["XSTATS_HOMEBREW_PREVIEW_DIR"] {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try #require(image.representation(using: .png, properties: [:])).write(
        to: directory.appendingPathComponent(
          "impact-\(language.languageCode)-\(dark ? "dark" : "light").png"))
    }
  }

  @Test(arguments: AppLanguage.allCases.filter { $0 != .system && $0 != .chinese })
  func impactStringsAreTranslatedWithoutChangingGlobalLanguage(language: AppLanguage) {
    for text in [
      "来源识别依据", "操作影响", "查看影响预览", "以下已安装软件包依赖此项目，暂不能卸载。",
      "正在读取操作影响…", "无法生成操作预览，请刷新清单后重试",
      "来自上次保存的 Homebrew 来源记录，尚未通过本次清单核实。",
    ] {
      #expect(L10n.translate(text, language: language) != text)
    }
  }

  @Test func upgradeOutputIsBoundedByLinesAndCharacters() {
    let many = (0..<1_000).map { "line \($0)" }.joined(separator: "\n")
    let byLines = HomebrewImpactView.displayed(many, maxLines: 10, maxCharacters: 1_000_000)
    #expect(byLines.split(separator: "\n").count == 10 && byLines.hasPrefix("line 0\n"))
    let long = String(repeating: "x", count: 50_000)
    #expect(HomebrewImpactView.displayed(long, maxLines: 10, maxCharacters: 100).count == 100)
    #expect(HomebrewImpactView.displayed("a\nb") == "a\nb")
  }
}
