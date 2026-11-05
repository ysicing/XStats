// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct LaunchpadLayout: Codable, Equatable, Sendable {
  struct Item: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String?
    var apps: [String]

    static func app(_ id: String) -> Self { Self(id: id, apps: [id]) }
    var isFolder: Bool { name != nil }
  }

  var pages: [[Item]] = []

  mutating func reconcile(appIDs: [String], capacity: Int) {
    let available = Set(appIDs.prefix(2000))
    var seen = Set<String>()
    var folderIDs = Set<String>()
    pages = pages.prefix(2000).flatMap { page -> [[Item]] in
      let items = page.prefix(2000).flatMap { item -> [Item] in
        var item = item
        item.apps = item.apps.prefix(2000).filter {
          available.contains($0) && seen.insert($0).inserted
        }
        guard !item.apps.isEmpty else { return [] }
        if item.apps.count == 1 { return [.app(item.apps[0])] }
        guard item.isFolder else { return item.apps.map(Item.app) }
        if !item.id.hasPrefix("folder.") || !folderIDs.insert(item.id).inserted {
          item.id = "folder.\(UUID().uuidString)"
          folderIDs.insert(item.id)
        }
        item.name = String((item.name ?? "").prefix(80))
        return [item]
      }
      return Self.paginate(items, capacity: capacity)
    }
    for id in appIDs.prefix(2000) where seen.insert(id).inserted {
      if pages.isEmpty || pages[pages.count - 1].count >= max(1, capacity) {
        pages.append([])
      }
      pages[pages.count - 1].append(.app(id))
    }
  }

  func item(_ id: String) -> Item? { pages.joined().first { $0.id == id } }

  mutating func remove(_ id: String) {
    pages = pages.map { page in
      page.compactMap { original in
        if original.id == id { return nil }
        var item = original
        item.apps.removeAll { $0 == id }
        if item.apps.isEmpty { return nil }
        return item.apps.count == 1 ? .app(item.apps[0]) : item
      }
    }
  }

  /// 页边界保留到插入完成，避免移走某页最后一项后目标页下标发生偏移。
  mutating func move(_ id: String, toPage page: Int, before target: String?, capacity: Int) {
    guard page >= 0, page <= pages.count, id != target else { return }
    guard
      let source = item(id)
        ?? pages.joined().first(where: { $0.apps.contains(id) }).map({
          _ in Item.app(id)
        })
    else { return }
    remove(id)
    while pages.count <= page { pages.append([]) }
    let index =
      target.flatMap { target in pages[page].firstIndex { $0.id == target } }
      ?? pages[page].count
    pages[page].insert(source, at: index)
    pages = pages.flatMap { Self.paginate($0, capacity: capacity) }
  }

  mutating func group(_ source: String, into target: String, name: String) {
    guard source != target,
      let sourceItem = item(source)
        ?? pages.joined().first(where: { $0.apps.contains(source) }).map({
          _ in Item.app(source)
        }),
      !sourceItem.isFolder, let targetItem = item(target),
      !targetItem.apps.contains(source)
    else { return }
    remove(source)
    for page in pages.indices {
      guard let index = pages[page].firstIndex(where: { $0.id == target }) else { continue }
      if targetItem.isFolder {
        pages[page][index].apps.append(source)
      } else {
        pages[page][index] = Item(
          id: "folder.\(UUID().uuidString)", name: String(name.prefix(80)),
          apps: targetItem.apps + [source])
      }
      break
    }
    pages.removeAll { $0.isEmpty }
  }

  mutating func rename(_ folder: String, to name: String) {
    let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    guard !name.isEmpty else { return }
    for page in pages.indices {
      if let index = pages[page].firstIndex(where: { $0.id == folder && $0.isFolder }) {
        pages[page][index].name = name
      }
    }
  }

  static func paginate<Element>(_ items: [Element], capacity: Int) -> [[Element]] {
    let capacity = max(1, capacity)
    return stride(from: 0, to: items.count, by: capacity).map {
      Array(items[$0..<min($0 + capacity, items.count)])
    }
  }
}

@MainActor
final class LaunchpadLayoutStore {
  private let defaults: UserDefaults
  private let key = "launchpadLayout"
  init(defaults: UserDefaults) { self.defaults = defaults }

  func load() -> LaunchpadLayout? {
    guard let data = defaults.data(forKey: key), data.count <= 2_000_000 else { return nil }
    return try? JSONDecoder().decode(LaunchpadLayout.self, from: data)
  }

  func save(_ layout: LaunchpadLayout) {
    guard let data = try? JSONEncoder().encode(layout), data.count <= 2_000_000 else { return }
    defaults.set(data, forKey: key)
  }
}

enum LaunchpadAvailability {
  static var isSupported: Bool {
    supports(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
  }

  static func supports(majorVersion: Int) -> Bool { majorVersion >= 26 }
}
