import Foundation
import Localization

public enum CleanCategory: String, Sendable, CaseIterable, Identifiable {
    case system, browser, developer, downloads, trash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: tr("系统")
        case .browser: tr("浏览器")
        case .developer: tr("开发者")
        case .downloads: tr("下载")
        case .trash: tr("废纸篓")
        }
    }
}

public enum DeletionPolicy: Sendable {
    /// 可再生的缓存与日志：直接删除，空间立即释放
    case delete
    /// 用户文件（安装包、未完成下载）：移到废纸篓，可恢复
    case trash
}

public enum SkipReason: Sendable, Equatable, Hashable {
    case appRunning(String)
    case needsFullDiskAccess
    case toolUnavailable(String)
    case recentlyModified
    case protected

    public var title: String {
        switch self {
        case .appRunning(let name): tr("\(name) 正在运行")
        case .needsFullDiskAccess: tr("需要完全磁盘访问权限")
        case .toolUnavailable(let tool): tr("未找到 \(tool)，无法安全清理")
        case .recentlyModified: tr("刚刚被使用")
        case .protected: tr("受保护")
        }
    }
}

/// 扫描所需的外部环境，便于在测试中替换
public struct CleanEnvironment: Sendable {
    public var home: String
    public var runningBundleIdentifiers: @Sendable () -> Set<String>
    public var now: @Sendable () -> Date
    public var isToolAvailable: @Sendable (String) -> Bool
    public var runTool: @Sendable (String, [String]) async throws -> ToolRunResult

    public init(home: String = NSHomeDirectory(),
                runningBundleIdentifiers: @escaping @Sendable () -> Set<String>,
                now: @escaping @Sendable () -> Date = Date.init,
                isToolAvailable: (@Sendable (String) -> Bool)? = nil,
                runTool: (@Sendable (String, [String]) async throws -> ToolRunResult)? = nil) {
        self.home = home
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.now = now
        self.isToolAvailable = isToolAvailable ?? { DeveloperToolRunner.executable(named: $0, home: home) != nil }
        self.runTool = runTool ?? { try await DeveloperToolRunner.run($0, arguments: $1, home: home) }
    }
}

public struct CleanRule: Sendable, Identifiable {
    public let id: String
    public let category: CleanCategory
    public let title: String
    public let detail: String
    public let symbol: String
    public let selectedByDefault: Bool
    public let policy: DeletionPolicy
    /// 这些应用运行时整条规则跳过（例如浏览器）
    public let blockingApps: [(bundleID: String, name: String)]
    /// 条目名为反向域名（如 com.foo.bar）时，对应应用运行中则跳过该条目
    public let checksOwnerApp: Bool
    /// 最近修改过的条目视为正在使用
    public let minimumAge: TimeInterval
    public let requiredTool: String?
    let cleanWithTool: (@Sendable (CleanEnvironment) async throws -> Void)?
    /// 列出候选条目（顶层文件或目录）
    let locate: @Sendable (CleanEnvironment) throws -> [URL]

    init(id: String, category: CleanCategory, title: String, detail: String, symbol: String,
         selectedByDefault: Bool = true, policy: DeletionPolicy = .delete,
         blockingApps: [(bundleID: String, name: String)] = [], checksOwnerApp: Bool = false,
         minimumAge: TimeInterval = 120, requiredTool: String? = nil,
         cleanWithTool: (@Sendable (CleanEnvironment) async throws -> Void)? = nil,
         locate: @escaping @Sendable (CleanEnvironment) throws -> [URL]) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.selectedByDefault = selectedByDefault
        self.policy = policy
        self.blockingApps = blockingApps
        self.checksOwnerApp = checksOwnerApp
        self.minimumAge = minimumAge
        self.requiredTool = requiredTool
        self.cleanWithTool = cleanWithTool
        self.locate = locate
    }

    public var usesToolCleaner: Bool { cleanWithTool != nil }
}

public struct CleanItem: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let size: UInt64
}

public struct RuleScan: Sendable, Identifiable {
    public var id: String { rule.id }
    public let rule: CleanRule
    /// 按大小降序
    public let items: [CleanItem]
    public let skippedCount: Int
    /// 整条规则被阻止的原因（浏览器运行中、缺少权限或对应工具不可用）
    public let blocked: SkipReason?

    public var totalSize: UInt64 { items.reduce(0) { $0 + $1.size } }
    public var isCleanable: Bool { blocked == nil && !items.isEmpty }
}

public struct CleanReport: Sendable {
    public var freedBytes: UInt64 = 0
    public var removedCount = 0
    public var skippedCount = 0
    public var failures: [String] = []
    /// 移到废纸篓的大小（不会立即释放）
    public var trashedBytes: UInt64 = 0
}
