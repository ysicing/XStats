// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Security

/// 只从应用本身与受限的嵌套 bundle 中收集身份，不用开发团队或通用 helper 名称推断归属。
struct AppUninstallIdentity: Sendable {
  let identifiers: Set<String>
  let names: Set<String>
  /// 小写的完整名称候选；只用于受限目录中的精确匹配，名称本身不能证明独占归属。
  let nameVariants: Set<String>
  let applicationGroups: Set<String>
  let teamIdentifier: String?

  init(
    identifiers: Set<String>, names: Set<String>, applicationGroups: Set<String> = [],
    teamIdentifier: String? = nil
  ) {
    let validNames = Set(names.compactMap(Self.validName))
    self.identifiers = Set(identifiers.compactMap(Self.validIdentifier))
    self.names = validNames
    self.nameVariants = Set(validNames.flatMap { Self.safeNameVariants(for: $0) })
    self.applicationGroups = Set(applicationGroups.compactMap(Self.validIdentifier))
    self.teamIdentifier = teamIdentifier.flatMap(Self.validTeamIdentifier)
  }

  init(app: InstalledApp) {
    var identifiers = Set([app.bundleIdentifier])
    var names = Set([app.name, app.url.deletingPathExtension().lastPathComponent])
    var groups = Set<String>()
    var teamIdentifier: String?

    // 父目录的系统别名（例如 /var）可以规范化，应用本身与内部路径不接受符号链接。
    if !Task.isCancelled, AppUninstaller.isDirectoryWithoutSymlink(app.url) {
      let root = app.url.resolvingSymlinksInPath().standardizedFileURL
      if let metadata = Self.metadata(at: root, inside: root) {
        if let identifier = metadata["CFBundleIdentifier"] as? String {
          identifiers.insert(identifier)
        }
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
          if let name = metadata[key] as? String { names.insert(name) }
        }
      }
      if let signature = Self.signature(at: root) {
        groups.formUnion(signature.groups)
        teamIdentifier = signature.teamIdentifier
      }
      for bundle in Self.embeddedBundles(in: root) {
        if Task.isCancelled { break }
        if let metadata = Self.metadata(at: bundle, inside: root),
          let identifier = metadata["CFBundleIdentifier"] as? String
        {
          identifiers.insert(identifier)
          if let signature = Self.signature(at: bundle) { groups.formUnion(signature.groups) }
        }
      }
    }

    self.init(
      identifiers: identifiers, names: names, applicationGroups: groups,
      teamIdentifier: teamIdentifier)
  }

  static func validIdentifier(_ value: String) -> String? {
    // 当前工具链的 Release 构建会误判 CharacterSet 方法引用，成员检查使用显式闭包。
    guard !value.isEmpty, value.utf8.count <= 255 else { return nil }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    let alphanumeric = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    guard parts.count >= 2,
      parts.allSatisfy({ part in
        !part.isEmpty && part.unicodeScalars.allSatisfy({ allowed.contains($0) })
          && part.unicodeScalars.contains(where: { alphanumeric.contains($0) })
      })
    else { return nil }
    return value
  }

  static func validName(_ value: String) -> String? {
    guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
      return nil
    }
    let name = value.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
      !name.contains("/"), !name.contains("\\")
    else { return nil }
    return name
  }

  /// 保留产品的版本和渠道，只转换名称里的空格；不从包名、厂商名或通用 helper 名推测产品。
  static func safeNameVariants(for value: String) -> Set<String> {
    guard let name = validName(value), name.count >= 2,
      !genericCompactNames.contains(compactName(name))
    else { return [] }
    let words = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let variants = [
      name, words.joined(separator: " "), words.joined(),
      words.joined(separator: "-"), words.joined(separator: "_"),
    ]
    return Set(
      variants.compactMap { variant in
        let lower = variant.lowercased()
        guard lower.count >= 2, !genericCompactNames.contains(compactName(lower)) else {
          return nil
        }
        return lower
      })
  }

  /// 调用方先按目录规则去掉允许的文件后缀，再进行完整名称比较。
  func matchesName(_ candidate: String) -> Bool {
    guard let name = Self.validName(candidate) else { return false }
    return nameVariants.contains(name.lowercased())
  }

  /// 报告文件的产品名后必须有独立分隔符，FooBar 不能成为 Foo 的报告。
  func matchesReportName(_ stem: String) -> Bool {
    guard let name = Self.validName(stem) else { return false }
    let lower = name.lowercased()
    return nameVariants.contains {
      lower == $0 || lower.hasPrefix($0 + "-") || lower.hasPrefix($0 + "_")
    }
  }

  private static func compactName(_ value: String) -> String {
    value.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
  }

  /// 这些词常作为共享状态目录或多个产品的运行进程名，不能单独用来推断残留归属。
  private static let genericNames: Set<String> = [
    "app", "application", "applications", "application support", "cache", "caches", "code",
    "config", "configuration",
    "container", "containers", "crashhandler", "crash handler", "data", "electron",
    "electron helper", "extension",
    "framework", "group containers", "helper", "library", "log", "logs", "plugin", "preferences",
    "runner", "service",
    "shared", "system", "updater", "widget",
  ]
  private static let genericCompactNames = Set(genericNames.map(compactName))

  static func validTeamIdentifier(_ value: String) -> String? {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    guard !value.isEmpty, value.utf8.count <= 64,
      value.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else { return nil }
    return value
  }

  static func applicationGroups(from entitlements: [String: Any]) -> Set<String> {
    let groups = entitlements["com.apple.security.application-groups"] as? [Any] ?? []
    return Set(groups.compactMap { ($0 as? String).flatMap(validIdentifier) })
  }

  /// 必须实际位于根 bundle 内，且整个内部路径不能经由符号链接。
  static func isSafeURL(_ url: URL, inside root: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    guard path == rootPath || path.hasPrefix(rootPath + "/"),
      AppUninstaller.isDirectoryWithoutSymlink(root),
      AppUninstaller.isUnredirected(url, home: rootPath),
      let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
      values.isSymbolicLink != true
    else { return false }
    return true
  }

  static func metadata(at bundle: URL, inside root: URL) -> [String: Any]? {
    let url = bundle.appendingPathComponent("Contents/Info.plist")
    guard isSafeURL(bundle, inside: root), isSafeURL(url, inside: root),
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576,
      let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    else { return nil }
    return plist as? [String: Any]
  }

  static func embeddedBundles(in root: URL) -> [URL] {
    let locations = [
      "Contents/Frameworks", "Contents/XPCServices", "Contents/PlugIns",
      "Contents/Library/LoginItems",
    ]
    let ignoredDirectories: Set<String> = [
      "Resources", "_CodeSignature", "MacOS", "Headers", "Modules",
    ]
    var pending = locations.map { (url: root.appendingPathComponent($0), depth: 0) }
    var visited = Set<String>()
    var results: [URL] = []
    var examined = 0
    let manager = FileManager.default

    // 取消可返回部分身份，外层扫描随后抛错，禁止发布部分候选。
    while !Task.isCancelled, !pending.isEmpty, examined < 512, results.count < 64 {
      let (directory, depth) = pending.removeFirst()
      guard depth <= 8, isSafeURL(directory, inside: root), visited.insert(directory.path).inserted,
        let children = try? manager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
          options: .skipsHiddenFiles)
      else { continue }
      for child in children.sorted(by: { $0.path < $1.path }) {
        guard !Task.isCancelled, examined < 512, results.count < 64 else { break }
        examined += 1
        guard isSafeURL(child, inside: root),
          let values = try? child.resourceValues(forKeys: [.isDirectoryKey]),
          values.isDirectory == true
        else { continue }
        if ["app", "xpc", "appex"].contains(child.pathExtension.lowercased()),
          let info = metadata(at: child, inside: root),
          let identifier = info["CFBundleIdentifier"] as? String,
          validIdentifier(identifier) != nil
        {
          results.append(child)
        }
        if depth < 8, !ignoredDirectories.contains(child.lastPathComponent) {
          pending.append((child, depth + 1))
        }
      }
    }
    return results
  }

  private struct Signature {
    let groups: Set<String>
    let teamIdentifier: String?
  }

  private static func signature(at url: URL) -> Signature? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
      return nil
    }
    let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
    guard SecStaticCodeCheckValidity(code, validationFlags, nil) == errSecSuccess else {
      return nil
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let dictionary = information as? [String: Any]
    else { return nil }
    let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    let team = (dictionary[kSecCodeInfoTeamIdentifier as String] as? String).flatMap(
      validTeamIdentifier)
    return Signature(groups: applicationGroups(from: entitlements), teamIdentifier: team)
  }
}
