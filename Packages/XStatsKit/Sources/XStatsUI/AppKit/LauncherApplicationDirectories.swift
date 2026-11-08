// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

extension Notification.Name {
  static let launcherApplicationsChanged = Notification.Name("launcherApplicationsChanged")
}

/// 目录授权仅保存在本机偏好，不加入 SettingsDocument 的备份白名单。
struct LauncherApplicationDirectories {
  struct Directory: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let path: String
    let bookmark: Data
  }

  enum DirectoryError: Error, Equatable {
    case notDirectory, applicationBundle, unreadable, limitReached
  }

  static let maximumCount = 16
  static let defaultsKey = "launcher.applicationDirectoryBookmarks"
  private let defaults: UserDefaults
  let notificationCenter: NotificationCenter

  init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
    self.defaults = defaults
    self.notificationCenter = notificationCenter
  }

  var directories: [Directory] { snapshot.directories }

  /// 返回 false 表示已包含该规范路径（包括默认目录），不会重复授权或通知。
  @discardableResult
  func add(_ url: URL) throws -> Bool {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    let canonical = try Self.validatedDirectory(url)
    var saved = directories
    let paths =
      saved.map(\.path)
      + CommandBarApplications.directories.map {
        $0.resolvingSymlinksInPath().standardizedFileURL.path
      }
    guard !paths.contains(canonical.path) else { return false }
    guard saved.count < Self.maximumCount else { throw DirectoryError.limitReached }
    let bookmark = try url.bookmarkData(
      options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
      includingResourceValuesForKeys: nil, relativeTo: nil)
    saved.append(Directory(id: UUID(), path: canonical.path, bookmark: bookmark))
    try save(saved)
    return true
  }

  @discardableResult
  func remove(_ id: UUID) throws -> Bool {
    let saved = directories
    let remaining = saved.filter { $0.id != id }
    guard remaining.count != saved.count else { return false }
    try save(remaining)
    return true
  }

  /// 解析不弹授权框、不挂载离线卷；授权必须覆盖路径解析与整个扫描，离开闭包统一释放。
  /// 失效书签保留供用户移除，不将暂时不可用的目录视作应用已被卸载。
  func withResolvedDirectories<Result>(
    _ body: ([URL], Bool) throws -> Result
  ) throws -> Result {
    let saved = snapshot
    var incomplete = saved.isIncomplete
    var resolved: [URL] = []
    var accessed: [URL] = []
    var paths = Set<String>()
    defer {
      for url in accessed.reversed() { url.stopAccessingSecurityScopedResource() }
    }
    for directory in saved.directories {
      try Task.checkCancellation()
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: directory.bookmark,
          options: [.withSecurityScope, .withoutUI, .withoutMounting],
          relativeTo: nil, bookmarkDataIsStale: &stale)
        if url.startAccessingSecurityScopedResource() { accessed.append(url) }
        let canonical = try Self.validatedDirectory(url)
        if paths.insert(canonical.path).inserted { resolved.append(canonical) }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        incomplete = true
      }
    }
    try Task.checkCancellation()
    return try body(resolved, incomplete)
  }

  private var snapshot: (directories: [Directory], isIncomplete: Bool) {
    guard let value = defaults.object(forKey: Self.defaultsKey) else { return ([], false) }
    guard let data = value as? Data, data.count <= 1_048_576,
      let decoded = try? JSONDecoder().decode([Directory].self, from: data)
    else { return ([], true) }
    var seen = Set<UUID>()
    let valid = decoded.prefix(Self.maximumCount).filter {
      !$0.path.isEmpty && $0.path.utf8.count <= 32_768 && !$0.bookmark.isEmpty
        && seen.insert($0.id).inserted
    }
    return (valid, valid.count != decoded.count)
  }

  private func save(_ directories: [Directory]) throws {
    let data = try JSONEncoder().encode(directories)
    guard data.count <= 1_048_576 else { throw DirectoryError.limitReached }
    defaults.set(data, forKey: Self.defaultsKey)
    Log.app.info("Launcher application directories changed: \(directories.count, privacy: .public)")
    notificationCenter.post(name: .launcherApplicationsChanged, object: nil)
  }

  private static func validatedDirectory(_ url: URL) throws -> URL {
    guard url.isFileURL else { throw DirectoryError.notDirectory }
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    guard !canonical.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else {
      throw DirectoryError.applicationBundle
    }
    let values = try canonical.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else { throw DirectoryError.notDirectory }
    let manager = FileManager.default
    guard manager.isReadableFile(atPath: canonical.path),
      manager.isExecutableFile(atPath: canonical.path)
    else { throw DirectoryError.unreadable }
    return canonical
  }
}
