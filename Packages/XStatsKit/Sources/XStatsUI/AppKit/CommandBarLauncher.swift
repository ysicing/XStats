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

  static let maxApplications = 2_000
  static let maxVisited = 10_000

  static func scan() throws -> [AppCommand] {
    try scanResult().commands
  }

  static func scan(directories: [URL]) throws -> [AppCommand] {
    try scanResult(directories: directories).commands
  }

  static func scanResult() throws -> (commands: [AppCommand], isTruncated: Bool) {
    try scanResult(directories: directories, customDirectories: LauncherApplicationDirectories())
  }

  static func scanResult(
    directories: [URL], customDirectories: LauncherApplicationDirectories
  ) throws -> (commands: [AppCommand], isTruncated: Bool) {
    try customDirectories.withResolvedDirectories { custom, incomplete in
      let result = try scanResult(
        directories: directories + custom,
        optionalDirectories: Set(directories.map { $0.standardizedFileURL.path }))
      return (result.commands, result.isTruncated || incomplete)
    }
  }

  /// 仅访问根目录和一层分类目录；不进入应用包、不使用 Spotlight 或卸载器的全盘清单。
  /// `isTruncated` 也涵盖目录不可用或枚举失败，调用方不得据此清理用户数据。
  static func scanResult(directories: [URL]) throws -> (
    commands: [AppCommand], isTruncated: Bool
  ) {
    try scanResult(directories: directories, optionalDirectories: [])
  }

  private static func scanResult(directories: [URL], optionalDirectories: Set<String>) throws -> (
    commands: [AppCommand], isTruncated: Bool
  ) {
    let manager = FileManager.default
    var paths = Set<String>()
    var scannedDirectories = Set<String>()
    var commands: [AppCommand] = []
    var visited = 0
    var isTruncated = false
    for directory in directories {
      try Task.checkCancellation()
      let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
      guard scannedDirectories.insert(canonical.path).inserted else { continue }
      guard !canonical.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else {
        isTruncated = true
        continue
      }
      do {
        let values = try canonical.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true, manager.isReadableFile(atPath: canonical.path),
          manager.isExecutableFile(atPath: canonical.path)
        else {
          isTruncated = true
          continue
        }
      } catch {
        let missing = (error as? CocoaError)?.code == .fileReadNoSuchFile
        if !missing || !optionalDirectories.contains(directory.standardizedFileURL.path) {
          isTruncated = true
        }
        continue
      }
      guard
        let enumerator = manager.enumerator(
          at: canonical, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles],
          errorHandler: { _, _ in
            isTruncated = true
            return !Task.isCancelled
          })
      else {
        isTruncated = true
        continue
      }
      for case let candidate as URL in enumerator {
        try Task.checkCancellation()
        visited += 1
        if visited > maxVisited || commands.count >= maxApplications {
          isTruncated = true
          break
        }
        let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values == nil { isTruncated = true }
        // 对符号链接或已经自动跳过的包再次 skip，会跳过后续目录。
        if values?.isDirectory == true, values?.isSymbolicLink != true,
          enumerator.level >= 2 || candidate.pathExtension.lowercased() == "app"
        {
          enumerator.skipDescendants()
        }
        guard candidate.pathExtension.lowercased() == "app" else { continue }
        let url = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard manager.isReadableFile(atPath: url.path), manager.isExecutableFile(atPath: url.path)
        else {
          isTruncated = true
          continue
        }
        guard paths.insert(url.path).inserted else { continue }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let info = metadata(at: infoURL) else {
          if manager.fileExists(atPath: infoURL.path) { isTruncated = true }
          continue
        }
        guard info["CFBundlePackageType"] as? String == "APPL",
          let bundle = Bundle(url: url)
        else { continue }
        // Bundle 按路径缓存元数据；只借用其本地化资源定位，刷新时直接读取文件。
        let localized =
          bundle.url(forResource: "InfoPlist", withExtension: "strings")
          .flatMap { metadata(at: $0) } ?? [:]
        let filename = url.deletingPathExtension().lastPathComponent
        let displayName = manager.displayName(atPath: url.path)
        let finderName =
          displayName.lowercased().hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        let nameCandidates: [Any?] = [
          localized["CrAppModeShortcutName"] ?? info["CrAppModeShortcutName"],
          localized["CFBundleDisplayName"],
          localized["CFBundleName"],
          info["CFBundleDisplayName"],
          finderName != filename ? finderName : nil,
          info["CFBundleName"],
          finderName,
          filename,
        ]
        let title =
          nameCandidates.compactMap {
            ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
          }
          .first { !$0.isEmpty } ?? filename
        commands.append(
          AppCommand(
            id: "application.\(url.path)", title: title, symbol: "app",
            keywords: "\(filename) \(info["CFBundleIdentifier"] as? String ?? "")",
            action: .openApplication(url),
            applicationCategory: info["LSApplicationCategoryType"] as? String))
      }
      try Task.checkCancellation()
      if visited > maxVisited || commands.count >= maxApplications {
        isTruncated = true
        break
      }
    }
    try Task.checkCancellation()
    let sorted = commands.sorted {
      let comparison = $0.title.localizedStandardCompare($1.title)
      return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
    }
    return (sorted, isTruncated)
  }

  private static func metadata(at url: URL) -> [String: Any]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let maximumBytes = 1024 * 1024
    guard let data = try? handle.read(upToCount: maximumBytes + 1),
      data.count <= maximumBytes
    else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
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
