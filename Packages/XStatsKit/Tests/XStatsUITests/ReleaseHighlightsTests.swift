// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import AppKit
import Localization
import Testing
@testable import XStatsUI

struct ReleaseHighlightsTests {
  @Test func singleAndSkippedReleasesUseDifferentLayouts() throws {
    let catalog = try #require(ReleaseHighlightsCatalog.bundled)
    let single = try #require(catalog.page(after: "1.6.7", through: "1.7.0"))
    #expect(single.singleVersion == "1.7.0")
    #expect(single.items.map(\.feature.id) == ["activity", "sync"])

    let recent = try #require(catalog.page(after: "1.6.3", through: "1.7.0"))
    #expect(recent.singleVersion == nil)
    #expect(
      recent.items.map(\.feature.id) == ["activity", "sync", "dashboard", "clones", "remoteAI"])
    #expect(recent.items.map(\.version) == ["1.7.0", "1.7.0", "1.6.7", "1.6.6", "1.6.6"])
  }

  @Test func emptyReleasesCountTowardTheWindowAndPriorityPrecedesDisplayOrder() throws {
    func feature(_ id: String, priority: Int = 1) -> ReleaseHighlightsCatalog.Feature {
      let copy = ReleaseHighlightsCatalog.Feature.Copy(title: id, detail: id)
      return .init(
        id: id, zh: copy, en: copy, symbol: "star", priority: priority, experimental: nil)
    }
    let catalog = ReleaseHighlightsCatalog(releases: [
      .init(version: "1.2.0", features: [feature("outside", priority: 9)]),
      .init(version: "1.3.0", features: [feature("important", priority: 3)]),
      .init(version: "1.4.0", features: [feature("retired", priority: 9)]),
      .init(version: "1.5.0", features: []),
      .init(version: "1.6.0", features: [], retiredFeatureIDs: ["retired"]),
      .init(version: "1.7.0", features: (1...5).map { feature("feature\($0)") }),
      .init(version: "1.8.0", features: [feature("future")]),
    ])
    let page = try #require(catalog.page(after: "1.1.0", through: "1.7.0"))
    #expect(page.singleVersion == nil)
    #expect(
      page.items.map(\.feature.id) == ["feature1", "feature2", "feature3", "feature4", "important"])
    #expect(catalog.page(after: "1.3.0", through: "1.6.0") == nil)
    #expect(catalog.page(after: "1.7.0", through: "1.7.0") == nil)
    #expect(catalog.page(after: "1.8.0", through: "1.7.0") == nil)
  }

  @MainActor @Test(arguments: [false, true])
  func baselineAndAcknowledgmentPersist(existingInstall: Bool) throws {
    let suite = "XStats.ReleaseHighlightsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let progress = ReleaseHighlightProgress(defaults: defaults, existingInstall: existingInstall)
    progress.prepare(currentVersion: "1.7.0")
    #expect(progress.lastSeenVersion == (existingInstall ? "1.6.7" : "1.7.0"))
    progress.prepare(currentVersion: "1.7.1")
    #expect(progress.lastSeenVersion == (existingInstall ? "1.6.7" : "1.7.0"))
    progress.markSeen("1.7.1")
    progress.markSeen("1.6.7")
    let relaunched = ReleaseHighlightProgress(defaults: defaults, existingInstall: true)
    #expect(relaunched.lastSeenVersion == "1.7.1")
  }

  @MainActor @Test(arguments: ["1.6.7", "1.6.3"])
  func mainWindowPresentsOneSheetOnlyWhenRequested(lastSeen: String) async throws {
    _ = NSApplication.shared
    let suite = "XStats.ReleaseHighlightsWindowTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.releaseHighlightProgress.markSeen(lastSeen)
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient(),
      networkCacheDefaults: defaults)
    let controller = MainWindowController(model: model)
    defer { controller.close() }

    controller.show(tab: .settingsAbout)
    let window = try #require(controller.nsWindow)
    #expect(window.attachedSheet == nil)
    controller.show(tab: nil, releaseHighlightsVersion: "1.7.0")
    let sheet = try #require(window.attachedSheet)
    controller.show(tab: nil, releaseHighlightsVersion: "1.7.0")
    #expect(window.attachedSheet === sheet && window.sheets.count == 1)
    #expect(settings.releaseHighlightProgress.lastSeenVersion == lastSeen)

    if let path = ProcessInfo.processInfo.environment["XSTATS_HIGHLIGHTS_SNAPSHOT_DIR"] {
      sheet.appearance = NSAppearance(named: .aqua)
      try await Task.sleep(for: .milliseconds(500))
      let content = try #require(sheet.contentView)
      content.layoutSubtreeIfNeeded()
      let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: path).appending(path: "highlights-\(lastSeen).png"))
    }

    window.endSheet(sheet)
    settings.releaseHighlightProgress.markSeen("1.7.0")
    controller.show(tab: nil, releaseHighlightsVersion: "1.7.0")
    #expect(window.attachedSheet == nil)
  }

  @Test func bundledContentIsLocalized() throws {
    let catalog = try #require(ReleaseHighlightsCatalog.bundled)
    for feature in catalog.releases.flatMap(\.features) {
      for copy in [feature.zh, feature.en] {
        #expect(!copy.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!copy.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      #expect(feature.zh.detail != feature.en.detail)
      for language in AppLanguage.allCases {
        let resolved = language.resolved
        let chinese = resolved == .chinese || resolved == .traditionalChinese
        #expect(feature.copy(for: language) == (chinese ? feature.zh : feature.en))
      }
    }
    let strings = ["XStats 1.7.0 新版亮点", "XStats 最近版本亮点", "实验性"]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      for source in strings {
        #expect(L10n.translate(source, language: language) != source)
      }
    }
  }
}
