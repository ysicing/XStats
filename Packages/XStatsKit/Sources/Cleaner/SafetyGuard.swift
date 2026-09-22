import Foundation
import Localization

public enum SafetyError: Error, Sendable, Equatable, CustomStringConvertible {
    case notAbsolute
    case traversal
    case controlCharacter
    case outsideAllowedRoots
    case isRoot
    case protectedName(String)
    case applicationSupportNotCache

    public var description: String {
        switch self {
        case .notAbsolute: tr("不是绝对路径")
        case .traversal: tr("路径包含 ..")
        case .controlCharacter: tr("路径包含控制字符")
        case .outsideAllowedRoots: tr("不在允许清理的目录内")
        case .isRoot: tr("不能删除清理目录本身")
        case .protectedName(let name): tr("受保护的项目：\(name)")
        case .applicationSupportNotCache: tr("Application Support 中只允许清理缓存目录")
        }
    }
}

/// 所有删除操作的唯一入口校验。默认拒绝，只放行白名单目录内的条目。
public struct SafetyGuard: Sendable {
    public let home: String

    /// 相对家目录的允许根目录；条目必须位于其内部（不能是根目录本身）
    static let allowedRoots = [
        "Library/Caches",
        "Library/Logs",
        "Library/Application Support",
        "Library/Developer/Xcode/DerivedData",
        "Library/Developer/Xcode/Archives",
        "Library/Developer/CoreSimulator/Caches",
        ".npm",
        "go/pkg/mod",
        ".cargo/registry",
        ".cargo/git",
        ".cache/uv",
        ".yarn/berry/cache",
        "Library/pnpm/store",
        ".pnpm-store",
        ".bun/install/cache",
        "Downloads",
        ".Trash",
    ]

    /// Application Support 内只允许删除这些名字的缓存目录（浏览器配置目录下）
    static let applicationSupportCacheNames: Set<String> = ["Code Cache", "GPUCache", "CacheStorage", "Cache", "cache2", "ShaderCache", "GrShaderCache"]

    /// 路径任一段包含以下关键词即拒绝（小写匹配）
    static let protectedKeywords = [
        "keychain", "1password", "agilebits", "bitwarden", "lastpass", "dashlane", "enpass", "passwords",
        "tailscale", "wireguard", "clash", "surge", "shadowsocks", "v2ray", "nordvpn", "expressvpn", "networkextension",
        "mobile documents", "cloudkit", "cookies", "login data", "bookmarks", "history",
        // 改名后仍保护旧产品目录，避免清理时删除保留的旧日志或数据。
        "openstats", "xstats",
    ]

    public init(home: String = NSHomeDirectory()) {
        self.home = (home as NSString).standardizingPath
    }

    public func validate(_ url: URL) throws {
        let raw = url.path
        guard raw.hasPrefix("/") else { throw SafetyError.notAbsolute }
        guard !url.pathComponents.contains("..") else { throw SafetyError.traversal }
        guard !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw SafetyError.controlCharacter
        }
        try check(path: (raw as NSString).standardizingPath)
        // 解析符号链接（含父目录）后再检查一次：只会更严格，不会因此放行
        let resolved = url.resolvingSymlinksInPath().path
        if resolved != raw {
            try check(path: resolved)
        }
    }

    private func check(path: String) throws {
        let homePrefix = home + "/"
        guard path.hasPrefix(homePrefix) else { throw SafetyError.outsideAllowedRoots }
        let relative = String(path.dropFirst(homePrefix.count))

        guard let root = Self.allowedRoots.first(where: { relative == $0 || relative.hasPrefix($0 + "/") }) else {
            throw SafetyError.outsideAllowedRoots
        }
        guard relative != root else { throw SafetyError.isRoot }

        let inside = relative.dropFirst(root.count + 1)
        for component in inside.split(separator: "/") {
            let lower = component.lowercased()
            if let keyword = Self.protectedKeywords.first(where: { lower.contains($0) }) {
                throw SafetyError.protectedName(keyword)
            }
        }

        if root == "Library/Application Support" {
            let leaf = (path as NSString).lastPathComponent
            guard Self.applicationSupportCacheNames.contains(leaf) else { throw SafetyError.applicationSupportNotCache }
        }
    }
}
