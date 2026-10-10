// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Localization

/// 一个可以卸载的应用
public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleIdentifier: String
    public let version: String?
    /// 签名团队（可能未读取）；共享容器通过真实应用组或容器记录识别。
    public let teamIdentifier: String?

    public init(url: URL, name: String, bundleIdentifier: String, version: String?, teamIdentifier: String?) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.teamIdentifier = teamIdentifier
    }
}

/// 应用留下的文件
public struct AppLeftover: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case application, support, caches, preferences, containers, savedState, logs, webData, launchAgents

        public var title: String {
            switch self {
            case .application: tr("应用本体")
            case .support: tr("应用数据")
            case .caches: tr("缓存")
            case .preferences: tr("偏好设置")
            case .containers: tr("沙盒容器")
            case .savedState: tr("窗口状态")
            case .logs: tr("日志与崩溃报告")
            case .webData: tr("网页数据")
            case .launchAgents: tr("登录启动项")
            }
        }
    }

    public var id: String { url.path }
    public let url: URL
    public let kind: Kind
    public let size: UInt64
    /// 共享或归属不确定的数据默认不选，由用户确认是否移除。
    public let requiresReview: Bool

    public init(url: URL, kind: Kind, size: UInt64, requiresReview: Bool = false) {
        self.url = url; self.kind = kind; self.size = size; self.requiresReview = requiresReview
    }
}

public enum AppUninstallError: Error, Sendable, Equatable, CustomStringConvertible {
    case systemApp
    case currentApp
    case running
    case notAnApp
    case unsafePath(String)

    public var description: String {
        switch self {
        case .systemApp: tr("系统自带的应用不能卸载")
        case .currentApp: tr("不能在 XStats 内卸载或退出 XStats 自身")
        case .running: tr("应用正在运行，请先退出")
        case .notAnApp: tr("不是应用程序")
        case .unsafePath(let path): tr("不在可卸载的位置：\(path)")
        }
    }
}

/// 依据应用身份、容器元数据和明确路径查找残留；共享候选默认保留。
public enum AppUninstaller {
    public static func applicationDirectories(home: String = NSHomeDirectory()) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: home).appendingPathComponent("Applications")]
    }

    /// /Applications 与 ~/Applications 下的应用（含一层子文件夹），按名称排序。
    /// 可取消；遍历中止时抛错，不发布部分列表。
    public static func scanInstalledApps(home: String = NSHomeDirectory(), excluding excludedIdentifiers: Set<String> = []) throws -> [InstalledApp] {
        try installedApps(in: applicationDirectories(home: home), excluding: excludedIdentifiers,
                          checkCancellation: { try Task.checkCancellation() })
    }

    static func installedApps(in directories: [URL], excluding excludedIdentifiers: Set<String>,
                              checkCancellation: () throws -> Void) throws -> [InstalledApp] {
        try checkCancellation()
        var apps: [InstalledApp] = []
        let manager = FileManager.default
        for directory in directories {
            try checkCancellation()
            let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for entry in entries {
                try checkCancellation()
                if entry.pathExtension == "app" {
                    if let app = app(at: entry) { apps.append(app) }
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try checkCancellation()
                    let nested = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                    for candidate in nested {
                        try checkCancellation()
                        guard candidate.pathExtension == "app" else { continue }
                        if let app = app(at: candidate) { apps.append(app) }
                    }
                }
            }
        }
        // 取消不得继续做筛选、排序，也不能把扫描到的一部分列表当成成功结果。
        try checkCancellation()
        return apps
            .filter { !excludedIdentifiers.contains($0.bundleIdentifier) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func app(at url: URL) -> InstalledApp? {
        guard url.pathExtension == "app", let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return nil }
        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(url: url, name: name, bundleIdentifier: identifier,
                            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                            teamIdentifier: nil)
    }

    /// 系统、Apple 应用与当前应用的副本均不可卸载；不允许应用路径被符号链接重定向。
    public static func validate(_ app: InstalledApp, home: String = NSHomeDirectory(),
                                currentBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        let path = app.url.resolvingSymlinksInPath().path
        guard app.url.pathExtension == "app" else { throw AppUninstallError.notAnApp }
        if (try? app.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw AppUninstallError.unsafePath(path) }
        if path.hasPrefix("/System/") || app.bundleIdentifier.hasPrefix("com.apple.") { throw AppUninstallError.systemApp }
        if currentBundleIdentifier?.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame { throw AppUninstallError.currentApp }
        let original = app.url.standardizedFileURL.path
        let homeApplications = URL(fileURLWithPath: home).resolvingSymlinksInPath().appendingPathComponent("Applications").path + "/"
        // /Applications 和 home 以下的 Applications 不能通过解析可替换的根目录来扩大白名单。
        let inSystemApplications = original.hasPrefix("/Applications/") && path == original
        let inHomeApplications = path.hasPrefix(homeApplications) && isUnredirected(app.url, home: home)
        guard inSystemApplications || inHomeApplications else { throw AppUninstallError.unsafePath(path) }
    }

    public static func leftovers(for app: InstalledApp, home: String = NSHomeDirectory()) -> [AppLeftover] {
        leftovers(for: app, home: home, identity: AppUninstallIdentity(app: app))
    }

    /// 可取消；身份和大小计量均在调用方的后台任务内执行，取消后不发布部分结果。
    public static func scanLeftovers(for app: InstalledApp, home: String = NSHomeDirectory()) throws -> [AppLeftover] {
        try Task.checkCancellation()
        let identity = AppUninstallIdentity(app: app)
        try Task.checkCancellation()
        return try leftovers(for: app, home: home, identity: identity, checkCancellation: { try Task.checkCancellation() })
    }

    static func leftovers(for app: InstalledApp, home: String, identity: AppUninstallIdentity) -> [AppLeftover] {
        (try? leftovers(for: app, home: home, identity: identity, checkCancellation: {})) ?? []
    }

    static func leftovers(for app: InstalledApp, home: String, identity: AppUninstallIdentity,
                                  checkCancellation: () throws -> Void) throws -> [AppLeftover] {
        try checkCancellation()
        let library = URL(fileURLWithPath: home).appendingPathComponent("Library")
        let manager = FileManager.default
        var results: [AppLeftover] = []

        func matches(_ name: String) -> Bool {
            matchesIdentifier(name, app.bundleIdentifier) || identity.identifiers.contains { matchesIdentifier(name, $0) }
        }

        func auxiliaryMatch(_ name: String) -> Bool {
            matches(name) && !matchesIdentifier(name, app.bundleIdentifier)
        }

        func add(_ url: URL, _ kind: AppLeftover.Kind, review: Bool = false) throws {
            try checkCancellation()
            let path = url.standardizedFileURL.path
            guard manager.fileExists(atPath: path),
                  (try? validateLeftover(url, for: app, home: home)) != nil else { return }
            if let ancestor = results.firstIndex(where: { path.hasPrefix($0.url.standardizedFileURL.path + "/") }) {
                if review && !results[ancestor].requiresReview {
                    let item = results[ancestor]
                    results[ancestor] = AppLeftover(url: item.url, kind: item.kind, size: item.size, requiresReview: true)
                }
                return
            }
            if let index = results.firstIndex(where: { $0.url.standardizedFileURL.path == path }) {
                if review && !results[index].requiresReview {
                    let item = results[index]
                    results[index] = AppLeftover(url: item.url, kind: item.kind, size: item.size, requiresReview: true)
                }
                return
            }
            var requiresReview = review
            results.removeAll { item in
                if item.url.standardizedFileURL.path.hasPrefix(path + "/") { requiresReview = requiresReview || item.requiresReview; return true }
                return false
            }
            results.append(AppLeftover(url: url, kind: kind, size: try CleanEngine.scanAllocatedSize(of: url, checkCancellation: checkCancellation), requiresReview: requiresReview))
        }

        func entries(_ relative: String) throws -> [URL] {
            try checkCancellation()
            let directory = library.appendingPathComponent(relative)
            guard isUnredirected(directory, home: home) else { return [] }
            // 保留调用方的 home 路径写法；FileManager 的 URL 形式可能把 /var 转成 /private/var。
            return ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
                .sorted().map { directory.appendingPathComponent($0) }
        }

        func scan(_ relative: String, _ kind: AppLeftover.Kind, names: Bool = false, review: Bool = false) throws {
            for entry in try entries(relative) {
                try checkCancellation()
                let named = names && identity.names.contains(entry.lastPathComponent)
                if matches(entry.lastPathComponent) || named {
                    try add(entry, kind, review: review || auxiliaryMatch(entry.lastPathComponent) || (named && !matches(entry.lastPathComponent)))
                }
            }
        }

        /// 只深入厂商目录一层，选择匹配的应用子项，保留厂商目录本身。
        func scanNested(_ relative: String, _ kind: AppLeftover.Kind) throws {
            for parent in try entries(relative) {
                try checkCancellation()
                guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      !results.contains(where: { $0.url == parent }), isUnredirected(parent, home: home) else { continue }
                let children = ((try? manager.contentsOfDirectory(atPath: parent.path)) ?? [])
                    .map { parent.appendingPathComponent($0) }
                for child in children {
                    try checkCancellation()
                    if matches(child.lastPathComponent) { try add(child, kind, review: auxiliaryMatch(child.lastPathComponent)) }
                }
            }
        }

        try add(app.url, .application)
        try scan("Application Support", .support, names: true)
        try scan("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments", .support)
        try scan("Application Support/CrashReporter", .logs)
        try scan("Caches", .caches)
        try scan("Caches/org.sparkle-project.Sparkle", .caches)
        try scan("Caches/SentryCrash", .caches)
        // Sentry 的目录使用 CFBundleName 而非包名；同名数据可能共用，默认不选。
        for entry in try entries("Caches/SentryCrash") where identity.names.contains(entry.lastPathComponent) {
            try add(entry, .caches, review: true)
        }
        try scanNested("Application Support", .support)
        try scanNested("Caches", .caches)
        try scanNested("Logs", .logs)
        try scan("HTTPStorages", .caches)
        try scan("Preferences", .preferences)
        try scan("Preferences/ByHost", .preferences)
        for entry in try entries("Containers") {
            try checkCancellation()
            let owner = containerIdentifier(at: entry, home: home)
            if let owner {
                if identity.identifiers.contains(owner) { try add(entry, .containers, review: owner != app.bundleIdentifier && !owner.hasPrefix(app.bundleIdentifier + ".")) }
            } else if matches(entry.lastPathComponent) { try add(entry, .containers, review: auxiliaryMatch(entry.lastPathComponent)) }
        }
        try scan("Application Scripts", .containers)
        for relative in ["Group Containers", "Application Scripts"] {
            for entry in try entries(relative) {
                try checkCancellation()
                let name = entry.lastPathComponent
                let owner = containerIdentifier(at: entry, home: home)
                let group = identity.applicationGroups.contains(name)
                    || owner.map { identity.applicationGroups.contains($0) } == true
                    || (relative == "Group Containers" && identity.identifiers.contains { id in
                        supportsDerivedNames(id) && (name.hasSuffix("." + id) || name == "group." + id || name.hasPrefix("group." + id + "."))
                    })
                if group || matches(name) { try add(entry, .containers, review: true) }
            }
        }
        try scan("Saved Application State", .savedState)
        try scan("Logs", .logs, names: true)
        for entry in try entries("Logs/DiagnosticReports") where identity.names.contains(where: {
            entry.lastPathComponent.hasPrefix($0 + "-") || entry.lastPathComponent.hasPrefix($0 + "_")
        }) { try add(entry, .logs, review: !matches(entry.lastPathComponent)) }
        try scan("WebKit", .webData)
        try scan("Cookies", .webData)
        try scan("LaunchAgents", .launchAgents)

        for path in knownPaths(for: app.bundleIdentifier) {
            try add(URL(fileURLWithPath: home).appendingPathComponent(path.relative), path.kind, review: path.review)
        }
        try checkCancellation()
        return results
    }

    private static func containerIdentifier(at directory: URL, home: String) -> String? {
        let metadata = directory.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard isUnredirected(metadata, home: home),
              let values = try? metadata.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: metadata),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }

    private static func knownPaths(for identifier: String) -> [(relative: String, kind: AppLeftover.Kind, review: Bool)] {
        switch identifier.lowercased() {
        case "com.microsoft.vscode":
            [("Library/Application Support/Code", .support, false), (".vscode", .support, false), (".vscode-shared", .support, true)]
        case "com.microsoft.vscodeinsiders":
            [("Library/Application Support/Code - Insiders", .support, false), (".vscode-insiders", .support, false), (".vscode-shared", .support, true)]
        case "company.thebrowser.browser":
            [("Library/Application Support/Arc", .support, false), ("Library/Caches/Arc", .caches, false)]
        case "com.google.chrome":
            [("Library/Application Support/Google/Chrome", .support, false), ("Library/Caches/Google/Chrome", .caches, false)]
        default: []
        }
    }

    private static let libraryRoots = ["Application Support", "Caches", "HTTPStorages", "Preferences", "Containers",
                                       "Application Scripts", "Group Containers", "Saved Application State", "Logs", "WebKit", "Cookies", "LaunchAgents"]
    private static let sharedNames: Set<String> = ["google", "microsoft", "mozilla", "jetbrains", "adobe", "bravesoftware", "opera software",
                                                   "steam", "objective-see", "apple", "crashreporter", "sentrycrash", "org.sparkle-project.sparkle", "com.apple.sharedfilelist"]

    /// 在扫描和回收前重查：只允许固定目录内的应用条目，拒绝共享根及 home 以下的符号链接重定向。
    public static func validateLeftover(_ url: URL, for app: InstalledApp, home: String = NSHomeDirectory()) throws {
        if url.standardizedFileURL == app.url.standardizedFileURL {
            try validate(app, home: home)
            return
        }
        let base = URL(fileURLWithPath: home).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard !url.pathComponents.contains(".."), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              path.hasPrefix(base + "/"), isUnredirected(url, home: home) else { throw AppUninstallError.unsafePath(path) }
        let relative = String(path.dropFirst(base.count + 1))
        if knownPaths(for: app.bundleIdentifier).contains(where: { $0.relative == relative }) { return }
        guard let root = libraryRoots.first(where: { relative.hasPrefix("Library/" + $0 + "/") }) else { throw AppUninstallError.unsafePath(path) }
        let inside = String(relative.dropFirst(("Library/" + root + "/").count))
        if !inside.contains("/"), sharedNames.contains(inside.lowercased()) { throw AppUninstallError.unsafePath(path) }
        if relative == "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            || relative == "Library/Preferences/ByHost" || relative == "Library/Logs/DiagnosticReports" { throw AppUninstallError.unsafePath(path) }
    }

    private static func isUnredirected(_ url: URL, home: String) -> Bool {
        let originalHome = URL(fileURLWithPath: home).standardizedFileURL
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(originalHome.path + "/") else { return false }
        let relative = String(path.dropFirst(originalHome.path.count + 1))
        let expected = originalHome.resolvingSymlinksInPath().appendingPathComponent(relative).standardizedFileURL.path
        return url.resolvingSymlinksInPath().standardizedFileURL.path == expected
    }

    /// 名字等于包名，或是包名后接“.”的派生名（com.example.app.plist、com.example.app.savedState、com.example.app.helper）
    ///
    /// 前缀匹配要求包名至少三段反向域名：`leftovers` 会扫描 Preferences、Caches、Containers 等
    /// 十余个目录，若放行 “com” 这类残缺包名，`hasPrefix("com.")` 会把 com.apple.dock.plist 在内的
    /// 所有 com.* 条目都当成残留列出并默认勾选。精确匹配不受影响，短包名仍能删掉自己的同名条目。
    static func matchesIdentifier(_ name: String, _ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let lowered = name.lowercased()
        let id = identifier.lowercased()
        if lowered == id { return true }
        guard supportsDerivedNames(identifier) else { return false }
        return lowered.hasPrefix(id + ".")
    }

    private static func supportsDerivedNames(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
    }

    // MARK: 程序坞

    /// 从程序坞的 persistent-apps 中去掉指向该应用的图标，返回是否有改动（调用方随后重启程序坞）
    public static func removingDockTile(for appURL: URL, from tiles: [[String: Any]]) -> [[String: Any]]? {
        let target = appURL.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let filtered = tiles.filter { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String else { return true }
            let path = (URL(string: string)?.path ?? string).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path != target
        }
        return filtered.count == tiles.count ? nil : filtered
    }
}
