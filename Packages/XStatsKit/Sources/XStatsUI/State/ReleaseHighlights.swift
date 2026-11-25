// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Updates

struct ReleaseHighlightsCatalog: Decodable, Sendable {
  struct Feature: Decodable, Sendable {
    struct Copy: Decodable, Equatable, Sendable {
      let title: String
      let detail: String
    }

    let id: String
    let zh: Copy
    let en: Copy
    let symbol: String
    var singleVersionSymbol: String? = nil
    var showsActivityChart: Bool? = nil
    let priority: Int
    let experimental: Bool?

    func copy(for language: AppLanguage) -> Copy {
      language.resolved.isChinese ? zh : en
    }
  }

  struct Release: Decodable, Sendable {
    let version: String
    let features: [Feature]
    var retiredFeatureIDs: [String]? = nil
  }

  struct Item: Identifiable, Sendable {
    let version: String
    let feature: Feature

    var id: String { feature.id }
  }

  struct Page: Sendable {
    let singleVersion: String?
    let items: [Item]
  }

  let releases: [Release]

  static let bundled: Self? = {
    guard let url = Bundle.module.url(forResource: "ReleaseHighlights", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let catalog = try? JSONDecoder().decode(Self.self, from: data)
    else {
      Log.app.error("Unable to read bundled release highlights")
      return nil
    }
    return catalog
  }()

  func page(after lastSeen: String, through current: String) -> Page? {
    let window =
      releases
      .filter {
        UpdateFeed.isNewer($0.version, than: lastSeen)
          && !UpdateFeed.isNewer($0.version, than: current)
      }
      .sorted { UpdateFeed.isNewer($0.version, than: $1.version) }
      .prefix(5)
    var seen = Set<String>()
    let candidates = window.flatMap { release in
      seen.formUnion(release.retiredFeatureIDs ?? [])
      return release.features.compactMap { feature in
        seen.insert(feature.id).inserted ? Item(version: release.version, feature: feature) : nil
      }
    }
    guard !candidates.isEmpty else { return nil }

    let selected = Set(
      candidates.indices.sorted { lhs, rhs in
        let lhsPriority = candidates[lhs].feature.priority
        let rhsPriority = candidates[rhs].feature.priority
        return lhsPriority == rhsPriority ? lhs < rhs : lhsPriority > rhsPriority
      }.prefix(5))
    return Page(
      singleVersion: window.count == 1 ? window.first?.version : nil,
      items: candidates.indices.filter { selected.contains($0) }.map { candidates[$0] })
  }
}

@MainActor
struct ReleaseHighlightProgress {
  private static let key = "releaseHighlights.lastSeenVersion"
  private static let legacyBaseline = "1.6.7"
  private let defaults: UserDefaults
  private let existingInstall: Bool

  init(defaults: UserDefaults, existingInstall: Bool) {
    self.defaults = defaults
    self.existingInstall = existingInstall
  }

  var lastSeenVersion: String? { defaults.string(forKey: Self.key) }

  func prepare(currentVersion: String) {
    guard lastSeenVersion == nil, UpdateFeed.isNewer(currentVersion, than: "0") else { return }
    let hasLegacyUpgrade =
      existingInstall && UpdateFeed.isNewer(currentVersion, than: Self.legacyBaseline)
    markSeen(hasLegacyUpgrade ? Self.legacyBaseline : currentVersion)
  }

  func markSeen(_ version: String) {
    guard UpdateFeed.isNewer(version, than: lastSeenVersion ?? "0") else { return }
    defaults.set(version, forKey: Self.key)
  }
}
