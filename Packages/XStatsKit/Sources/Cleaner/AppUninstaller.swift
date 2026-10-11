// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Darwin
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

/// 已验证的卸载候选与未能读取的位置分开返回，部分失败不会伪装成“没有残留”。
public struct AppLeftoverScan: Sendable {
    public let items: [AppLeftover]
    public let unreadablePaths: [URL]
    public let otherInstalledCopies: [URL]
    /// 应用列表无法完整读取时，不确定是否存在其他副本，保留共用数据。
    public let installationCheckIncomplete: Bool
    let identity: AppUninstallIdentity?
    let applicationURL: URL?

    public init(items: [AppLeftover], unreadablePaths: [URL] = [], otherInstalledCopies: [URL] = [],
                installationCheckIncomplete: Bool = false) {
        self.items = items; self.unreadablePaths = unreadablePaths
        self.otherInstalledCopies = otherInstalledCopies; self.installationCheckIncomplete = installationCheckIncomplete
        identity = nil; applicationURL = nil
    }

    init(items: [AppLeftover], unreadablePaths: [URL], installations: AppInstallationCheck,
         identity: AppUninstallIdentity, applicationURL: URL) {
        self.items = items; self.unreadablePaths = unreadablePaths
        otherInstalledCopies = installations.otherInstalledCopies
        installationCheckIncomplete = !installations.unreadableDirectories.isEmpty
        self.identity = identity; self.applicationURL = applicationURL
    }
}

/// 副本检查不确定时保留数据；取消仍抛错，不把取消当成完整检查。
public struct AppInstallationCheck: Sendable {
    public let otherInstalledCopies: [URL]
    public let unreadableDirectories: [URL]
    public var preservesSharedData: Bool { !otherInstalledCopies.isEmpty || !unreadableDirectories.isEmpty }

    public init(otherInstalledCopies: [URL] = [], unreadableDirectories: [URL] = []) {
        self.otherInstalledCopies = otherInstalledCopies; self.unreadableDirectories = unreadableDirectories
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
        var unreadable: [URL] = []
        return try installedApps(in: directories, excluding: excludedIdentifiers, unreadable: &unreadable,
                                 checkCancellation: checkCancellation)
    }

    /// 安装目录无法枚举时不能排除其他副本；目录可遍历但不可列出时，其中的应用仍可能正常使用。
    /// 副本检查只读元数据，会跟随条目的符号链接（如 Nix 链接安装）；可卸载列表不展示链接条目。
    private static func installedApps(in directories: [URL], excluding excludedIdentifiers: Set<String>,
                                      unreadable: inout [URL], followsSymlinks: Bool = false,
                                      checkCancellation: () throws -> Void) throws -> [InstalledApp] {
        try checkCancellation()
        var apps: [InstalledApp] = []
        let manager = FileManager.default
        for directory in directories {
            try checkCancellation()
            if manager.fileExists(atPath: directory.path), !isDirectoryWithoutSymlink(directory) {
                unreadable.append(directory)
                continue
            }
            let entries: [URL]
            do { entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) }
            catch {
                let error = error as NSError
                if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError { unreadable.append(directory) }
                continue
            }
            for entry in entries {
                try checkCancellation()
                let target = followsSymlinks ? entry.resolvingSymlinksInPath() : entry
                if entry.pathExtension == "app" {
                    if let app = listedApp(at: entry, followsSymlinks: followsSymlinks, unreadable: &unreadable) { apps.append(app) }
                } else if isDirectoryWithoutSymlink(target) {
                    let nested: [URL]
                    do {
                        nested = try manager.contentsOfDirectory(at: target, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                    } catch {
                        if followsSymlinks { unreadable.append(entry) }
                        continue
                    }
                    for candidate in nested {
                        try checkCancellation()
                        guard candidate.pathExtension == "app",
                              let app = listedApp(at: entry.appendingPathComponent(candidate.lastPathComponent), followsSymlinks: followsSymlinks, unreadable: &unreadable) else { continue }
                        apps.append(app)
                    }
                }
            }
        }
        try checkCancellation()
        return apps.filter { !excludedIdentifiers.contains($0.bundleIdentifier) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 副本检查保留安装目录中的原始条目路径，提示中不出现链接目标。
    /// 严格读取失败时，只有确定不是可运行应用的条目可以跳过；其余情况无法排除副本，记为不可读。
    private static func listedApp(at entry: URL, followsSymlinks: Bool, unreadable: inout [URL]) -> InstalledApp? {
        guard followsSymlinks else { return app(at: entry) }
        let target = entry.resolvingSymlinksInPath()
        guard let app = app(at: target) else {
            if !isDefinitelyInvalidBundle(target) { unreadable.append(entry) }
            return nil
        }
        return InstalledApp(url: entry, name: app.name, bundleIdentifier: app.bundleIdentifier,
                            version: app.version, teamIdentifier: app.teamIdentifier)
    }

    /// 确定无效：Info.plist 不存在，或是 bundle 内的普通文件且能读取，但内容损坏或没有可用标识。
    /// 链接、内部路径重定向、非普通文件、超大或不可读的 Info.plist 都可能属于可启动的副本，不算无效。
    static func isDefinitelyInvalidBundle(_ bundle: URL) -> Bool {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        var information = stat()
        guard url.path.withCString({ lstat($0, &information) }) == 0 else { return errno == ENOENT || errno == ENOTDIR }
        guard information.st_mode & S_IFMT == S_IFREG, information.st_size <= 1_048_576,
              AppUninstallIdentity.isSafeURL(url, inside: bundle),
              let data = try? Data(contentsOf: url) else { return false }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return true }
        let identifier = (plist as? [String: Any])?["CFBundleIdentifier"] as? String
        return identifier.flatMap(AppUninstallIdentity.validName) == nil
    }

    public static func app(at url: URL) -> InstalledApp? {
        // 副本检查必须读取当前标识，不能沿用 Bundle 的旧 Info.plist 缓存。
        guard url.pathExtension == "app", let info = AppUninstallIdentity.metadata(at: url, inside: url),
              let rawIdentifier = info["CFBundleIdentifier"] as? String,
              let identifier = AppUninstallIdentity.validName(rawIdentifier) else { return nil }
        let name = (Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(url: url, name: name, bundleIdentifier: identifier,
                            version: info["CFBundleShortVersionString"] as? String, teamIdentifier: nil)
    }

    /// 系统、Apple 应用与当前应用的副本均不可卸载；不允许应用路径被符号链接重定向。
    public static func validate(_ app: InstalledApp, home: String = NSHomeDirectory(),
                                currentBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        let path = app.url.resolvingSymlinksInPath().path
        guard app.url.pathExtension == "app" else { throw AppUninstallError.notAnApp }
        var information = stat()
        if app.url.path.withCString({ lstat($0, &information) }) == 0 && information.st_mode & S_IFMT == S_IFLNK {
            throw AppUninstallError.unsafePath(path)
        }
        if path.hasPrefix("/System/") || app.bundleIdentifier.hasPrefix("com.apple.") { throw AppUninstallError.systemApp }
        if currentBundleIdentifier?.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame { throw AppUninstallError.currentApp }
        let original = app.url.standardizedFileURL.path
        let homeApplications = URL(fileURLWithPath: home).resolvingSymlinksInPath()
            .appendingPathComponent("Applications").resolvingSymlinksInPath().path + "/"
        // /Applications 和 home 以下的 Applications 不能通过解析可替换的根目录来扩大白名单。
        let applications = URL(fileURLWithPath: "/Applications")
        let inSystemApplications = original.hasPrefix("/Applications/")
            && isDirectoryWithoutSymlink(applications)
            && path.caseInsensitiveCompare(original) == .orderedSame
            && isUnredirected(app.url.deletingLastPathComponent(), home: applications.path)
        let inHomeApplications = path.hasPrefix(homeApplications) && isUnredirected(app.url, home: home)
        guard inSystemApplications || inHomeApplications else { throw AppUninstallError.unsafePath(path) }
    }

    public static func leftovers(for app: InstalledApp, home: String = NSHomeDirectory()) -> [AppLeftover] {
        leftovers(for: app, home: home, identity: AppUninstallIdentity(app: app))
    }

    /// 可取消；身份和大小计量均在调用方的后台任务内执行，取消后不发布部分结果。
    public static func scanLeftovers(for app: InstalledApp, home: String = NSHomeDirectory()) throws -> [AppLeftover] {
        try scanLeftoversReport(for: app, home: home).items
    }

    /// 无关位置不可读时保留完整计量的候选；应用本体无法验证或取消时仍抛错。
    public static func scanLeftoversReport(for app: InstalledApp, home: String = NSHomeDirectory()) throws -> AppLeftoverScan {
        try Task.checkCancellation()
        let identity = AppUninstallIdentity(app: app)
        try Task.checkCancellation()
        return try scanLeftoversReport(for: app, home: home, identity: identity,
                                      installations: checkOtherInstallations(of: app, home: home),
                                      userCache: userCacheDirectory(home: home))
    }

    static func scanLeftoversReport(for app: InstalledApp, home: String, identity: AppUninstallIdentity,
                                   installations: AppInstallationCheck, userCache: URL?) throws -> AppLeftoverScan {
        var unreadablePaths = Set(installations.unreadableDirectories)
        let items = try leftovers(for: app, home: home, identity: identity, unreadablePaths: &unreadablePaths,
                                  preserveSharedData: installations.preservesSharedData, userCache: userCache,
                                  checkCancellation: { try Task.checkCancellation() })
        return AppLeftoverScan(items: items, unreadablePaths: unreadablePaths.sorted { $0.path < $1.path },
                              installations: installations, identity: identity, applicationURL: app.url)
    }

    /// 在调用方的后台任务中检查固定安装目录；读取失败时不能确认没有其他副本。
    public static func checkOtherInstallations(of app: InstalledApp, home: String = NSHomeDirectory()) throws -> AppInstallationCheck {
        let directories = applicationDirectories(home: home)
        var unreadable: [URL] = []
        let installed = try installedApps(in: directories, excluding: [], unreadable: &unreadable, followsSymlinks: true,
                                         checkCancellation: { try Task.checkCancellation() })
        let copies = installed.filter {
            $0.bundleIdentifier.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame && !isSameItem($0.url, app.url)
        }.map(\.url)
        return AppInstallationCheck(otherInstalledCopies: copies, unreadableDirectories: unreadable)
    }

    static func leftovers(for app: InstalledApp, home: String, identity: AppUninstallIdentity) -> [AppLeftover] {
        (try? leftovers(for: app, home: home, identity: identity, checkCancellation: {})) ?? []
    }

    static func leftovers(for app: InstalledApp, home: String, identity: AppUninstallIdentity,
                                  checkCancellation: () throws -> Void) throws -> [AppLeftover] {
        var unreadablePaths = Set<URL>()
        return try leftovers(for: app, home: home, identity: identity, unreadablePaths: &unreadablePaths,
                             checkCancellation: checkCancellation)
    }

    private static func leftovers(for app: InstalledApp, home: String, identity: AppUninstallIdentity,
                                  unreadablePaths: inout Set<URL>, preserveSharedData: Bool = false, userCache: URL? = nil,
                                  checkCancellation: () throws -> Void) throws -> [AppLeftover] {
        try checkCancellation()
        let library = URL(fileURLWithPath: home).appendingPathComponent("Library")
        let manager = FileManager.default
        var results: [AppLeftover] = []

        func matches(_ name: String) -> Bool {
            matchesIdentifier(name, app.bundleIdentifier) || identity.identifiers.contains { matchesIdentifier(name, $0) }
        }

        // Code、Caches 这类单段标识可能就是共用目录名，同名条目只列出待确认，不默认勾选。
        let trustedIdentifier = AppUninstallIdentity.validIdentifier(app.bundleIdentifier) != nil
        func auxiliaryMatch(_ name: String) -> Bool {
            matches(name) && !(trustedIdentifier && matchesIdentifier(name, app.bundleIdentifier))
        }

        func add(_ url: URL, _ kind: AppLeftover.Kind, review: Bool = false) throws {
            try checkCancellation()
            let path = url.standardizedFileURL.path
            guard manager.fileExists(atPath: path),
                  (try? validateLeftover(url, for: app, home: home, userCache: userCache, identity: identity)) != nil else { return }
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
            let size: UInt64
            do {
                size = try CleanEngine.scanAllocatedSize(of: url, checkCancellation: checkCancellation)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if kind == .application { throw error }
                unreadablePaths.insert(url)
                return
            }
            var requiresReview = review
            results.removeAll { item in
                if item.url.standardizedFileURL.path.hasPrefix(path + "/") { requiresReview = requiresReview || item.requiresReview; return true }
                return false
            }
            results.append(AppLeftover(url: url, kind: kind, size: size, requiresReview: requiresReview))
        }

        func entries(_ relative: String) throws -> [URL] {
            try checkCancellation()
            let directory = library.appendingPathComponent(relative)
            guard isUnredirected(directory, home: home) else {
                if manager.fileExists(atPath: directory.path) { unreadablePaths.insert(directory) }
                return []
            }
            // 保留调用方的 home 路径写法；FileManager 的 URL 形式可能把 /var 转成 /private/var。
            guard manager.fileExists(atPath: directory.path) else { return [] }
            do {
                return try manager.contentsOfDirectory(atPath: directory.path)
                    .sorted().map { directory.appendingPathComponent($0) }
            } catch {
                unreadablePaths.insert(directory)
                return []
            }
        }

        func scan(_ relative: String, _ kind: AppLeftover.Kind, names: Bool = false, review: Bool = false) throws {
            for entry in try entries(relative) {
                try checkCancellation()
                let named = names && identity.matchesName(entry.lastPathComponent)
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
                let children: [URL]
                do {
                    children = try manager.contentsOfDirectory(atPath: parent.path).map { parent.appendingPathComponent($0) }
                } catch {
                    unreadablePaths.insert(parent)
                    continue
                }
                for child in children {
                    try checkCancellation()
                    if matches(child.lastPathComponent) { try add(child, kind, review: auxiliaryMatch(child.lastPathComponent)) }
                }
            }
        }

        try add(app.url, .application)
        guard !preserveSharedData else { return results }
        try scan("Application Support", .support, names: true)
        try scan("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments", .support)
        try scan("Application Support/CrashReporter", .logs)
        try scan("Caches", .caches, names: true)
        try scan("Caches/org.sparkle-project.Sparkle", .caches)
        try scan("Caches/SentryCrash", .caches)
        // Sentry 的目录使用 CFBundleName 而非包名；同名数据可能共用，默认不选。
        for entry in try entries("Caches/SentryCrash") where identity.matchesName(entry.lastPathComponent) {
            try add(entry, .caches, review: true)
        }
        try scanNested("Application Support", .support)
        try scanNested("Caches", .caches)
        try scanNested("Logs", .logs)
        try scan("HTTPStorages", .caches)
        try scan("Preferences", .preferences)
        for entry in try entries("Preferences") where entry.pathExtension.lowercased() == "plist"
            && identity.matchesName(entry.deletingPathExtension().lastPathComponent) {
            try add(entry, .preferences, review: !matches(entry.lastPathComponent))
        }
        try scan("Preferences/ByHost", .preferences)
        for entry in try entries("Containers") {
            try checkCancellation()
            let owner = containerIdentifier(at: entry, home: home)
            if let owner {
                if identity.identifiers.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) {
                    try add(entry, .containers, review: owner.caseInsensitiveCompare(app.bundleIdentifier) != .orderedSame)
                }
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
        for entry in try entries("Saved Application State") where entry.pathExtension.lowercased() == "savedstate"
            && identity.matchesName(entry.deletingPathExtension().lastPathComponent) {
            try add(entry, .savedState, review: !matches(entry.lastPathComponent))
        }
        try scan("Logs", .logs, names: true)
        for (relative, extensions) in [("Application Support/CrashReporter", Set(["plist"])),
                                       ("Logs/DiagnosticReports", Set(["ips", "crash", "spin", "diag"]))] {
            for entry in try entries(relative) where extensions.contains(entry.pathExtension.lowercased())
                && identity.matchesReportName(entry.deletingPathExtension().lastPathComponent) {
                try add(entry, .logs, review: !matches(entry.lastPathComponent))
            }
        }
        try scan("WebKit", .webData)
        try scan("WebKit/com.apple.WebKit.WebContent", .webData)
        try scan("Caches/com.apple.nsurlsessiond/Downloads", .caches)
        try scan("Cookies", .webData)
        try scan("LaunchAgents", .launchAgents)

        for path in knownPaths(for: app.bundleIdentifier) {
            try add(URL(fileURLWithPath: home).appendingPathComponent(path.relative), path.kind, review: path.review)
        }
        if let userCache {
            try checkCancellation()
            if isDirectoryWithoutSymlink(userCache) {
                do {
                    for name in try manager.contentsOfDirectory(atPath: userCache.path).sorted() {
                        try checkCancellation()
                        if matches(name) { try add(userCache.appendingPathComponent(name), .caches, review: auxiliaryMatch(name)) }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { unreadablePaths.insert(userCache) }
            } else { unreadablePaths.insert(userCache) }
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
        case "ai.opencode.desktop":
            [(".config/opencode", .support, true), (".cache/opencode", .caches, true)]
        default: []
        }
    }

    private static let libraryRoots = ["Application Support", "Caches", "HTTPStorages", "Preferences", "Containers",
                                       "Application Scripts", "Group Containers", "Saved Application State", "Logs", "WebKit", "Cookies", "LaunchAgents"]
    private static let sharedNames: Set<String> = ["google", "microsoft", "mozilla", "jetbrains", "adobe", "bravesoftware", "opera software",
                                                   "steam", "objective-see", "apple", "crashreporter", "sentrycrash", "org.sparkle-project.sparkle", "com.apple.sharedfilelist", "com.apple.webkit.webcontent", "com.apple.nsurlsessiond"]

    /// 在扫描和回收前重查：只允许固定目录内的应用条目，拒绝共享根及 home 以下的符号链接重定向。
    public static func validateLeftover(_ url: URL, for app: InstalledApp, home: String = NSHomeDirectory()) throws {
        try validateLeftover(url, for: app, home: home, userCache: userCacheDirectory(home: home))
    }

    /// 保留扫描时从真实 bundle 收集的组件身份；本体已移入废纸篓后仍可重试这些候选。
    public static func validateLeftover(_ url: URL, for app: InstalledApp, scan: AppLeftoverScan, home: String = NSHomeDirectory()) throws {
        if scan.applicationURL == nil {
            try validateLeftover(url, for: app, home: home)
            return
        }
        try validateLeftover(url, for: app, scan: scan, home: home, userCache: userCacheDirectory(home: home))
    }

    static func validateLeftover(_ url: URL, for app: InstalledApp, scan: AppLeftoverScan, home: String, userCache: URL?) throws {
        guard scan.applicationURL?.standardizedFileURL.path == app.url.standardizedFileURL.path,
              scan.items.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) else {
            throw AppUninstallError.unsafePath(url.path)
        }
        try validateLeftover(url, for: app, home: home, userCache: userCache, identity: scan.identity)
    }

    static func validateLeftover(_ url: URL, for app: InstalledApp, home: String, userCache: URL?, identity: AppUninstallIdentity? = nil) throws {
        let path = url.standardizedFileURL.path
        guard !url.pathComponents.contains(".."), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw AppUninstallError.unsafePath(path)
        }
        if url.standardizedFileURL == app.url.standardizedFileURL {
            try validate(app, home: home)
            return
        }
        let base = URL(fileURLWithPath: home).standardizedFileURL.path
        if let userCache, url.deletingLastPathComponent().standardizedFileURL.path == userCache.standardizedFileURL.path,
           isDirectoryWithoutSymlink(userCache),
           isUnredirected(url, home: userCache.path),
           (identity ?? AppUninstallIdentity(app: app)).identifiers.contains(where: { matchesIdentifier(url.lastPathComponent, $0) }) {
            return
        }
        guard path.hasPrefix(base + "/"), isUnredirected(url, home: home) else { throw AppUninstallError.unsafePath(path) }
        let relative = String(path.dropFirst(base.count + 1))
        if knownPaths(for: app.bundleIdentifier).contains(where: { $0.relative == relative }) { return }
        guard let root = libraryRoots.first(where: { relative.hasPrefix("Library/" + $0 + "/") }) else { throw AppUninstallError.unsafePath(path) }
        let inside = String(relative.dropFirst(("Library/" + root + "/").count))
        if !inside.contains("/"), sharedNames.contains(inside.lowercased()) { throw AppUninstallError.unsafePath(path) }
        if relative == "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            || relative == "Library/Preferences/ByHost" || relative == "Library/Logs/DiagnosticReports"
            || relative == "Library/Caches/com.apple.nsurlsessiond/Downloads"
            || relative == "Library/WebKit/com.apple.WebKit.WebContent" { throw AppUninstallError.unsafePath(path) }
    }

    static func isUnredirected(_ url: URL, home: String) -> Bool {
        let suppliedHome = URL(fileURLWithPath: home).standardizedFileURL
        let path = url.standardizedFileURL.path
        let roots = [suppliedHome, suppliedHome.resolvingSymlinksInPath().standardizedFileURL]
        guard let originalHome = roots.first(where: { path.hasPrefix($0.path + "/") || path == $0.path }) else { return false }
        let relative = path == originalHome.path ? "" : String(path.dropFirst(originalHome.path.count + 1))
        var current = originalHome
        // APFS 解析路径会规范实际大小写，不能用字符串相等判定符号链接。
        // 从可信 home 向下逐级 lstat，允许大小写规范化，拒绝任何层级的真实链接。
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component))
            var information = stat()
            guard current.path.withCString({ lstat($0, &information) }) == 0,
                  information.st_mode & S_IFMT != S_IFLNK else { return false }
        }
        return true
    }

    /// APFS 默认不区分大小写，路径字符串不同不能证明是另一副本；按设备与 inode 判断。
    static func isSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        var left = stat(), right = stat()
        guard lhs.path.withCString({ stat($0, &left) }) == 0, rhs.path.withCString({ stat($0, &right) }) == 0 else {
            return lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
        }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    /// URL 的资源属性可能缓存旧值；路径重查直接读取当前目录项。
    static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        var information = stat()
        return url.path.withCString({ lstat($0, &information) }) == 0 && information.st_mode & S_IFMT == S_IFDIR
    }

    /// 由系统提供当前用户的 /var/folders/.../C 路径；不扫描其他用户或整个临时根。
    private static func userCacheDirectory(home: String) -> URL? {
        guard URL(fileURLWithPath: home).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path else { return nil }
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard length > 1, length < 4096 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, length) == length else { return nil }
        let directory = buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { URL(fileURLWithPath: String(cString: $0)).standardizedFileURL }
        }
        guard let directory else { return nil }
        let path = directory.path
        let canonical: URL
        if path.hasPrefix("/var/folders/") {
            canonical = URL(fileURLWithPath: "/private" + path)
        } else {
            canonical = directory
        }
        let anchor = URL(fileURLWithPath: "/private/var/folders")
        guard canonical.lastPathComponent == "C", canonical.path.hasPrefix(anchor.path + "/"),
              isDirectoryWithoutSymlink(anchor),
              isUnredirected(canonical, home: anchor.path) else { return nil }
        var information = stat()
        guard canonical.path.withCString({ lstat($0, &information) }) == 0,
              information.st_mode & S_IFMT == S_IFDIR, information.st_uid == geteuid() else { return nil }
        return canonical
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
