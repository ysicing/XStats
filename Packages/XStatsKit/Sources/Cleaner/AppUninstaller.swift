import Foundation
import Localization

/// 一个可以卸载的应用
public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleIdentifier: String
    public let version: String?
    /// 签名团队，用于查找 Group Containers
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
}

public enum AppUninstallError: Error, Sendable, Equatable, CustomStringConvertible {
    case systemApp
    case running
    case notAnApp
    case unsafePath(String)

    public var description: String {
        switch self {
        case .systemApp: tr("系统自带的应用不能卸载")
        case .running: tr("应用正在运行，请先退出")
        case .notAnApp: tr("不是应用程序")
        case .unsafePath(let path): tr("不在可卸载的位置：\(path)")
        }
    }
}

/// 查找应用的残留文件。只按包名（bundle identifier）精确匹配或以“包名.”开头，
/// 应用名只用于 Application Support 与 Logs 下与应用同名的目录，避免误伤名字相近的其他应用
public enum AppUninstaller {
    public static func applicationDirectories(home: String = NSHomeDirectory()) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: home).appendingPathComponent("Applications")]
    }

    /// /Applications 与 ~/Applications 下的应用（含一层子文件夹），按名称排序
    public static func installedApps(home: String = NSHomeDirectory(), excluding excludedIdentifiers: Set<String> = []) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        let manager = FileManager.default
        for directory in applicationDirectories(home: home) {
            let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for entry in entries {
                if entry.pathExtension == "app" {
                    if let app = app(at: entry) { apps.append(app) }
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let nested = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                    apps += nested.filter { $0.pathExtension == "app" }.compactMap(app(at:))
                }
            }
        }
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

    /// 系统自带与 Apple 的应用不允许卸载
    public static func validate(_ app: InstalledApp, home: String = NSHomeDirectory()) throws {
        let path = app.url.resolvingSymlinksInPath().path
        guard app.url.pathExtension == "app" else { throw AppUninstallError.notAnApp }
        if path.hasPrefix("/System/") || app.bundleIdentifier.hasPrefix("com.apple.") { throw AppUninstallError.systemApp }
        let allowed = applicationDirectories(home: home).map { $0.path + "/" }
        guard allowed.contains(where: { path.hasPrefix($0) }) else { throw AppUninstallError.unsafePath(path) }
    }

    public static func leftovers(for app: InstalledApp, home: String = NSHomeDirectory()) -> [AppLeftover] {
        let library = URL(fileURLWithPath: home).appendingPathComponent("Library")
        let id = app.bundleIdentifier
        let manager = FileManager.default
        var results: [AppLeftover] = []
        var seen = Set<String>()

        func add(_ url: URL, _ kind: AppLeftover.Kind) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), manager.fileExists(atPath: path) else { return }
            seen.insert(path)
            results.append(AppLeftover(url: url, kind: kind, size: CleanEngine.allocatedSize(of: url)))
        }

        /// 目录下名字等于包名、以“包名.”开头或满足 extra 的条目
        func scan(_ relative: String, _ kind: AppLeftover.Kind, extra: (String) -> Bool = { _ in false }) {
            let directory = library.appendingPathComponent(relative)
            let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where matchesIdentifier(name, id) || extra(name) {
                add(directory.appendingPathComponent(name), kind)
            }
        }

        add(app.url, .application)
        scan("Application Support", .support) { $0 == app.name }
        scan("Caches", .caches)
        scan("HTTPStorages", .caches)
        scan("Preferences", .preferences)
        scan("Preferences/ByHost", .preferences)
        scan("Containers", .containers)
        scan("Application Scripts", .containers)
        scan("Group Containers", .containers) { name in
            // 形如 “TEAMID.com.example.app” 或 “group.com.example.app”
            name.hasSuffix("." + id) || name == "group." + id || name.hasPrefix("group." + id + ".")
        }
        scan("Saved Application State", .savedState)
        scan("Logs", .logs) { $0 == app.name }
        scan("Logs/DiagnosticReports", .logs) { $0.hasPrefix(app.url.deletingPathExtension().lastPathComponent + "-") }
        scan("WebKit", .webData)
        scan("Cookies", .webData)
        scan("LaunchAgents", .launchAgents)
        return results
    }

    /// 名字等于包名，或是包名后接“.”的派生名（com.example.app.plist、com.example.app.savedState、com.example.app.helper）
    static func matchesIdentifier(_ name: String, _ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let lowered = name.lowercased()
        let id = identifier.lowercased()
        return lowered == id || lowered.hasPrefix(id + ".")
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
