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
  case previewFailed(String)
  case recentlyModified
  case protected
  case excluded

  public var title: String {
    switch self {
    case .appRunning(let name): tr("\(name) 正在运行")
    case .needsFullDiskAccess: tr("需要完全磁盘访问权限")
    case .toolUnavailable(let tool): tr("未找到 \(tool)，无法安全清理")
    case .previewFailed(let detail): tr("预览失败：\(detail)")
    case .recentlyModified: tr("刚刚被使用")
    case .protected: tr("受保护")
    case .excluded: tr("已排除")
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
  /// 固定工具缓存的环境变量；自定义执行器必须显式支持，不能静默丢弃路径约束。
  public var runToolWithEnvironment:
    @Sendable (String, [String], [String: String]) async throws -> ToolRunResult
  var inspectTool: @Sendable (String, [String]) async throws -> ToolRunResult
  let toolEnvironment: [String: String]
  public var excludedPaths: [String]

  public init(
    home: String = NSHomeDirectory(),
    runningBundleIdentifiers: @escaping @Sendable () -> Set<String>,
    now: @escaping @Sendable () -> Date = Date.init,
    isToolAvailable: (@Sendable (String) -> Bool)? = nil,
    runTool: (@Sendable (String, [String]) async throws -> ToolRunResult)? = nil,
    runToolWithEnvironment: (
      @Sendable (String, [String], [String: String]) async throws -> ToolRunResult
    )? = nil,
    toolEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    excludedPaths: [String] = []
  ) {
    self.home = home
    self.runningBundleIdentifiers = runningBundleIdentifiers
    self.now = now
    self.isToolAvailable =
      isToolAvailable ?? { DeveloperToolRunner.executable(named: $0, home: home) != nil }
    self.runTool = runTool ?? { try await DeveloperToolRunner.run($0, arguments: $1, home: home) }
    self.runToolWithEnvironment =
      runToolWithEnvironment ?? { tool, arguments, overrides in
        if let runTool {
          guard overrides.isEmpty else { throw ToolCachePlanError.unknownScope }
          return try await runTool(tool, arguments)
        }
        return try await DeveloperToolRunner.run(
          tool, arguments: arguments, home: home, environmentOverrides: overrides)
      }
    self.inspectTool =
      runTool ?? {
        try await DeveloperToolRunner.run(
          $0, arguments: $1, home: home, timeout: 30, outputLimit: 8192)
      }
    self.toolEnvironment = toolEnvironment
    self.excludedPaths = CleanupExclusions.normalized(excludedPaths)
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
  /// 原生规则唯一入口：解析范围并生成本次计划；执行阶段不得重新拼接默认命令。
  let prepareTool: (@Sendable (CleanEnvironment) async throws -> ToolCachePlan)?
  /// 列出候选条目（顶层文件或目录）
  let locate: @Sendable (CleanEnvironment) throws -> [URL]

  init(
    id: String, category: CleanCategory, title: String, detail: String, symbol: String,
    selectedByDefault: Bool = true, policy: DeletionPolicy = .delete,
    blockingApps: [(bundleID: String, name: String)] = [], checksOwnerApp: Bool = false,
    minimumAge: TimeInterval = 120, requiredTool: String? = nil,
    prepareTool: (@Sendable (CleanEnvironment) async throws -> ToolCachePlan)? = nil,
    locate: @escaping @Sendable (CleanEnvironment) throws -> [URL]
  ) {
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
    self.prepareTool = prepareTool
    self.locate = locate
  }

  /// 原生规则不提供目录扫描回退；所有候选都必须来自 prepareTool 的本次计划。
  init(
    id: String, category: CleanCategory, title: String, detail: String, symbol: String,
    selectedByDefault: Bool = false, minimumAge: TimeInterval = 0, requiredTool: String,
    prepareTool: @escaping @Sendable (CleanEnvironment) async throws -> ToolCachePlan
  ) {
    self.init(
      id: id, category: category, title: title, detail: detail, symbol: symbol,
      selectedByDefault: selectedByDefault, minimumAge: minimumAge,
      requiredTool: requiredTool, prepareTool: prepareTool, locate: { _ in [] })
  }

  public var usesToolCleaner: Bool { prepareTool != nil }

  /// 确认提示与清理执行共用的删除方式；工具清理和清空废纸篓始终不可恢复。
  public func deletesPermanently(preferTrash: Bool) -> Bool {
    if usesToolCleaner || id == RuleCatalog.trash.id { return true }
    switch policy {
    case .delete: return !preferTrash
    case .trash: return false
    }
  }
}

public struct CleanItem: Sendable, Identifiable, Hashable {
  public var id: String { url.path }
  public let url: URL
  public let size: UInt64

  public init(url: URL, size: UInt64) {
    self.url = url
    self.size = size
  }
}

public struct RuleScan: Sendable, Identifiable {
  public var id: String { rule.id }
  public let rule: CleanRule
  /// 文件扫描按大小降序；原生命令预览保持其输出顺序。
  public let items: [CleanItem]
  public let skippedCount: Int
  /// 整条规则被阻止的原因（浏览器运行中、缺少权限或对应工具不可用）
  public let blocked: SkipReason?
  public var toolPreview: ToolCleanupPreview? = nil
  /// 跳过原因与读取失败分开记录，避免把保护/权限不足一律说成“使用中”。
  public var skippedReasons: [SkipReason: Int] = [:]
  public var unreadableCount: Int = 0
  /// 扫描时锁定的原生工具清理范围，随逐项选择一起传到执行阶段。
  public var toolCachePlan: ToolCachePlan? = nil

  public init(
    rule: CleanRule, items: [CleanItem], skippedCount: Int, blocked: SkipReason?,
    toolPreview: ToolCleanupPreview? = nil, skippedReasons: [SkipReason: Int] = [:],
    unreadableCount: Int = 0,
    toolCachePlan: ToolCachePlan? = nil
  ) {
    self.rule = rule
    self.items = items
    self.skippedCount = skippedCount
    self.blocked = blocked
    self.toolPreview = toolPreview
    self.skippedReasons = skippedReasons
    self.unreadableCount = unreadableCount
    self.toolCachePlan = toolCachePlan
  }

  public var totalSize: UInt64 { toolPreview?.totalSize ?? items.reduce(0) { $0 + $1.size } }
  /// 工具会整体清理其存储，预览不完整时不能按部分候选批准整个操作。
  public var isCleanable: Bool {
    blocked == nil && !items.isEmpty && (!rule.usesToolCleaner || unreadableCount == 0)
  }
}

/// 原生命令提供的清理计划；大小可能包括只按目录汇总、没有逐文件列出的内容。
public struct ToolCleanupPreview: Sendable {
  public let items: [CleanItem]
  public let totalSize: UInt64
  public let details: String
}

public struct CleanReport: Sendable {
  /// 取消是用户操作，保留已完成部分的统计，但不作为工具失败。
  public var wasCancelled = false
  /// 原生工具中途退出时，已释放空间可能未出现在报告中。
  public var hasUncertainFreedBytes = false
  public var freedBytes: UInt64 = 0
  public var removedCount = 0
  public var skippedCount = 0
  public var failures: [String] = []
  /// 移到废纸篓的大小（不会立即释放）
  public var trashedBytes: UInt64 = 0
}

/// 已完成的清理步骤数；文件逐项计数，外部工具作为一个步骤，避免把预览数量当成执行进度。
public struct CleanProgress: Sendable {
  public let completed: Int
  public let total: Int
  public let currentRule: String
  /// 当前规则在选中规则中的位置，从 1 开始。
  public let ruleNumber: Int
  public let ruleCount: Int
  public let currentRuleCompleted: Int
  public let currentRuleTotal: Int
  public let currentRuleStartedAt: Date
  /// 工具清理无法按文件报告进度；这里只提供扫描时的大小，不代表实际释放量。
  public let toolScannedBytes: UInt64?

  public init(
    completed: Int, total: Int, currentRule: String,
    ruleNumber: Int, ruleCount: Int, currentRuleCompleted: Int, currentRuleTotal: Int,
    currentRuleStartedAt: Date,
    toolScannedBytes: UInt64? = nil
  ) {
    self.completed = completed
    self.total = total
    self.currentRule = currentRule
    self.ruleNumber = ruleNumber
    self.ruleCount = ruleCount
    self.currentRuleCompleted = currentRuleCompleted
    self.currentRuleTotal = currentRuleTotal
    self.currentRuleStartedAt = currentRuleStartedAt
    self.toolScannedBytes = toolScannedBytes
  }
}
