// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

enum CommandBarSystemSetting: String, CaseIterable, Sendable {
  case network, bluetooth, displays, sound, keyboard, privacy

  var title: String {
    switch self {
    case .network: tr("系统设置：网络")
    case .bluetooth: tr("系统设置：蓝牙")
    case .displays: tr("系统设置：显示器")
    case .sound: tr("系统设置：声音")
    case .keyboard: tr("系统设置：键盘")
    case .privacy: tr("系统设置：隐私与安全性")
    }
  }

  var url: URL {
    let identifier: String
    switch self {
    case .network: identifier = "com.apple.Network-Settings.extension"
    case .bluetooth: identifier = "com.apple.BluetoothSettings"
    case .displays: identifier = "com.apple.Displays-Settings.extension"
    case .sound: identifier = "com.apple.Sound-Settings.extension"
    case .keyboard: identifier = "com.apple.Keyboard-Settings.extension"
    case .privacy: identifier = "com.apple.settings.PrivacySecurity.extension"
    }
    return URL(string: "x-apple.systempreferences:\(identifier)")!
  }
}

enum CommandBarApplications {
  static var directories: [URL] {
    [
      "/Applications", NSHomeDirectory() + "/Applications", "/System/Applications",
      "/System/Library/CoreServices/Applications",
    ].map { URL(fileURLWithPath: $0) }
  }

  /// 仅访问根目录和一层分类目录；不进入应用包、不使用 Spotlight 或卸载器的全盘清单。
  static func scan(directories: [URL] = directories) throws -> [AppCommand] {
    let manager = FileManager.default
    var paths = Set<String>()
    var commands: [AppCommand] = []
    var visited = 0
    for directory in directories {
      try Task.checkCancellation()
      guard
        let enumerator = manager.enumerator(
          at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles])
      else { continue }
      for case let candidate as URL in enumerator {
        try Task.checkCancellation()
        visited += 1
        if visited > 10_000 || commands.count >= 2_000 { break }
        let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // 对符号链接或已经自动跳过的包再次 skip，会跳过后续目录。
        if values?.isDirectory == true, values?.isSymbolicLink != true,
          enumerator.level >= 2 || candidate.pathExtension.lowercased() == "app"
        {
          enumerator.skipDescendants()
        }
        guard candidate.pathExtension.lowercased() == "app" else { continue }
        let url = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard paths.insert(url.path).inserted,
          let bundle = Bundle(url: url),
          bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
        else { continue }
        let filename = url.deletingPathExtension().lastPathComponent
        let displayName = manager.displayName(atPath: url.path)
        let title = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        commands.append(
          AppCommand(
            id: "application.\(url.path)", title: title, symbol: "app",
            keywords: "\(filename) \(bundle.bundleIdentifier ?? "")",
            action: .openApplication(url)))
      }
      if visited > 10_000 || commands.count >= 2_000 { break }
    }
    return commands.sorted {
      let comparison = $0.title.localizedStandardCompare($1.title)
      return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
    }
  }
}

/// 只保存稳定入口，不保存参数、搜索文本或频率统计；本机有界偏好不参与云同步。
@MainActor
final class CommandBarUsage {
  private let defaults: UserDefaults
  private(set) var favorites: [String]
  private(set) var recent: [String]
  private static let favoritesKey = "commandBar.favoriteIDs"
  private static let recentKey = "commandBar.recentIDs"

  init(defaults: UserDefaults) {
    self.defaults = defaults
    favorites = Self.load(Self.favoritesKey, limit: 8, defaults: defaults)
    recent = Self.load(Self.recentKey, limit: 10, defaults: defaults)
  }

  func toggleFavorite(_ id: String) {
    guard id.utf8.count <= 2048 else { return }
    if favorites.contains(id) {
      favorites.removeAll { $0 == id }
    } else if favorites.count < 8 {
      favorites.append(id)
    }
    defaults.set(favorites, forKey: Self.favoritesKey)
  }

  func record(_ command: AppCommand) {
    let id = command.usageID
    guard id.utf8.count <= 2048 else { return }
    recent.removeAll { $0 == id }
    recent.insert(id, at: 0)
    recent = Array(recent.prefix(10))
    defaults.set(recent, forKey: Self.recentKey)
  }

  func clearRecent() {
    recent = []
    defaults.removeObject(forKey: Self.recentKey)
  }

  func clearFavorites() {
    favorites = []
    defaults.removeObject(forKey: Self.favoritesKey)
  }

  private static func load(_ key: String, limit: Int, defaults: UserDefaults) -> [String] {
    var seen = Set<String>()
    return (defaults.stringArray(forKey: key) ?? []).prefix(64).filter {
      !$0.isEmpty && $0.utf8.count <= 2048 && seen.insert($0).inserted
    }.prefix(limit).map { $0 }
  }
}
