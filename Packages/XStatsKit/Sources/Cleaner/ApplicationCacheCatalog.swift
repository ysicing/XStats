// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

/// 只列出已确认的应用缓存子目录，不递归猜测应用数据目录中的缓存。
enum ApplicationCacheCatalog {
  static let chromiumCaches = [
    "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
  ]
  static let editorCaches = chromiumCaches + ["CachedData", "CachedExtensionVSIXs"]

  /// 通用规则始终让出这些目录，包括符号链接别名。Codex 根中还有用户状态，不能整体删除。
  /// Application Support 各项并非死配置：通用规则只扫描 Caches/Logs，但其中的符号链接别名
  /// 解析后会落到这些目录（例如 Caches/alias -> Application Support/Claude/Cache），
  /// 只有这里的保留根能拦住，删掉会使 genericRulesProtectFriendlyNamesHelpersAndAliases 失败。
  static let reservedRoots =
    [
      "Library/Caches/Codex", "Library/Caches/com.openai.codex",
    ]
    + [
      "Slack", "discord", "Microsoft/Teams", "Claude", "Antigravity", "Qoder", "CodeBuddy",
      "CodeBuddy CN", "Code", "Code - Insiders", "Cursor",
    ].map { "Library/Application Support/" + $0 }

  /// Qoder：来自第三方卸载资料（Mole）的 com.qoder.ide，本机未安装，未能直接核对 Info.plist。
  /// CodeBuddy CN：本机偏好文件名 com.tencent.codebuddycn 佐证；国际版 com.tencent.codebuddy
  /// 沿用既有登记且未能核实。标识不匹配时，仍由应用名称与 .app 目录名兜底拦截。
  static let qoderIdentifiers = ["com.qoder.ide"]
  static let codeBuddyIdentifiers = ["com.tencent.codebuddy", "com.tencent.codebuddycn"]

  private struct Owner {
    let directories: [String]
    let identifiers: [String]
    let names: [String]
  }

  // 目录名与 .app 名称并不总是一致；未能核实的产品标识不编造，由应用名称兜底。
  private static let owners: [Owner] = [
    Owner(
      directories: ["Slack"], identifiers: ["com.tinyspeck.slackmacgap", "com.slack.Slack"],
      names: ["Slack"]),
    Owner(directories: ["discord"], identifiers: ["com.hnc.Discord"], names: ["Discord"]),
    Owner(
      directories: ["Teams", "Microsoft Teams"],
      identifiers: ["com.microsoft.teams", "com.microsoft.teams2"], names: ["Microsoft Teams"]),
    Owner(
      directories: ["Claude"], identifiers: ["com.anthropic.claudefordesktop"], names: ["Claude"]),
    Owner(directories: ["Codex"], identifiers: ["com.openai.codex"], names: ["Codex"]),
    Owner(
      directories: ["Antigravity"], identifiers: ["com.google.antigravity"], names: ["Antigravity"]),
    Owner(directories: ["Qoder"], identifiers: ["com.qoder.ide"], names: ["Qoder"]),
    Owner(
      directories: ["CodeBuddy", "CodeBuddy CN"], identifiers: codeBuddyIdentifiers,
      names: ["CodeBuddy", "CodeBuddy CN"]),
    Owner(
      directories: ["Code", "Code - Insiders"],
      identifiers: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
      names: ["Visual Studio Code", "Visual Studio Code - Insiders", "Visual Studio Code Insiders"]),
    Owner(
      directories: ["Cursor"], identifiers: ["com.todesktop.230313mzl4w4u92"], names: ["Cursor"]),
  ]

  static func runningOwner(directory: String, identifiers: Set<String>, names: Set<String>)
    -> String?
  {
    guard
      let owner = owners.first(where: {
        $0.directories.contains { $0.caseInsensitiveCompare(directory) == .orderedSame }
          || $0.identifiers.contains { directory == $0 || directory.hasPrefix($0 + ".") }
      })
    else { return nil }
    if owner.identifiers.contains(where: { id in
      identifiers.contains { $0 == id || $0.hasPrefix(id + ".") }
    }) {
      return owner.names.first
    }
    return owner.names.first { name in
      names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
  }

  static var rules: [CleanRule] {
    [
      cache(
        id: "app.slack", name: "Slack", directories: ["Slack"], names: ["Cache"],
        bundleIDs: ["com.tinyspeck.slackmacgap", "com.slack.Slack"]),
      cache(
        id: "app.discord", name: "Discord", directories: ["discord"], names: ["Cache"],
        bundleIDs: ["com.hnc.Discord"]),
      cache(
        id: "app.teamsClassic", name: tr("Microsoft Teams（旧版）"), directories: ["Microsoft/Teams"],
        names: ["Cache", "Code Cache", "GPUCache"],
        bundleIDs: ["com.microsoft.teams", "com.microsoft.teams2"],
        applicationNames: ["Microsoft Teams"]),
      cache(
        id: "app.claude", name: "Claude", directories: ["Claude"], names: chromiumCaches,
        bundleIDs: ["com.anthropic.claudefordesktop"]),
      cache(
        id: "app.antigravity", name: "Antigravity", directories: ["Antigravity"],
        names: chromiumCaches, bundleIDs: ["com.google.antigravity"]),
      cache(
        id: "app.qoder", name: "Qoder", directories: ["Qoder"], names: editorCaches,
        bundleIDs: qoderIdentifiers),
      cache(
        id: "app.codebuddy", name: "CodeBuddy", directories: ["CodeBuddy", "CodeBuddy CN"],
        names: editorCaches, bundleIDs: codeBuddyIdentifiers,
        applicationNames: ["CodeBuddy", "CodeBuddy CN"]),
      cache(
        id: "app.codex", name: "Codex",
        directories: [
          "Codex/Default", "Codex/Default/Partitions/codex-browser-app", "Codex/codex-browser-app",
        ], names: ["Cache", "Code Cache"], bundleIDs: ["com.openai.codex"], root: "Library/Caches"),
    ]
  }

  static func cache(
    id: String, name: String, directories: [String], names: [String], bundleIDs: [String],
    applicationNames: [String]? = nil, root: String = "Library/Application Support",
    category: CleanCategory = .system, previewOnly: Bool = false
  ) -> CleanRule {
    let paths = directories.flatMap { directory in names.map { root + "/" + directory + "/" + $0 } }
    return CleanRule(
      id: id, category: category, title: tr("\(name) 缓存"),
      detail: previewOnly
        ? tr("已确认的缓存目录；占用不代表可安全删除。")
        : tr("仅清理已确认的缓存目录，保留账号、设置和本地数据"),
      symbol: category == .developer ? "chevron.left.forwardslash.chevron.right" : "archivebox",
      selectedByDefault: false, previewOnly: previewOnly,
      blockingApps: bundleIDs.map { ($0, name) },
      requiresUnredirectedPath: true, cacheRelativePaths: paths,
      blockingApplicationNames: applicationNames ?? [name]
    ) { environment in
      return try paths.map { URL(fileURLWithPath: environment.home).appendingPathComponent($0) }
        .filter { url in
          do {
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
          } catch  where isMissingOrNotDirectory(error) {
            // 候选或其父级不存在，或父级是普通文件（ENOTDIR）：只跳过该候选，不让整条规则失败。
            return false
          }
        }
    }
  }

  /// 不存在或路径中间层不是目录；Cocoa 可能把 ENOENT/ENOTDIR 包在 underlying error 里。
  static func isMissingOrNotDirectory(_ error: Error) -> Bool {
    let failure = error as NSError
    if failure.domain == NSCocoaErrorDomain,
      [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code)
    {
      return true
    }
    if failure.domain == NSPOSIXErrorDomain, [Int(ENOENT), Int(ENOTDIR)].contains(failure.code) {
      return true
    }
    guard let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
    return underlying.domain == NSPOSIXErrorDomain
      && [Int(ENOENT), Int(ENOTDIR)].contains(underlying.code)
  }
}
