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
  public var runningApplicationNames: @Sendable () -> Set<String>
  public var now: @Sendable () -> Date
  public var isToolAvailable: @Sendable (String) -> Bool
  public var runTool: @Sendable (String, [String]) async throws -> ToolRunResult
  /// 固定工具缓存的环境变量；自定义执行器必须显式支持，不能静默丢弃路径约束。
  public var runToolWithEnvironment:
    @Sendable (String, [String], [String: String]) async throws -> ToolRunResult
  var inspectTool: @Sendable (String, [String]) async throws -> ToolRunResult
  /// 移到废纸篓的实现；默认走系统废纸篓，测试替换以免污染真实废纸篓。
  var trash: @Sendable (URL) throws -> Void = {
    try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
  }
  let toolEnvironment: [String: String]
  public var excludedPaths: [String]
  public var scanLimits = ScanLimits()

  public init(
    home: String = NSHomeDirectory(),
    runningBundleIdentifiers: @escaping @Sendable () -> Set<String>,
    runningApplicationNames: @escaping @Sendable () -> Set<String> = { [] },
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
    self.runningApplicationNames = runningApplicationNames
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
          $0, arguments: $1, home: home, timeout: 30, previewTimeout: 30, outputLimit: 8192)
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
  /// 新增检查只能预览；该约束同时用于界面选择和执行引擎。
  public let previewOnly: Bool
  public let policy: DeletionPolicy
  /// 这些应用运行时整条规则跳过（例如浏览器）
  public let blockingApps: [(bundleID: String, name: String)]
  /// 条目名为反向域名（如 com.foo.bar）时，对应应用运行中则跳过该条目
  public let checksOwnerApp: Bool
  /// 应用专属缓存不接受家目录以下任意层级的符号链接，执行前也重新检查。
  let requiresUnredirectedPath: Bool
  /// 应用缓存的精确家目录相对路径；扫描和执行使用相同的范围。
  let cacheRelativePaths: [String]
  let blockingApplicationNames: [String]
  /// 扫描 ~/Library/Caches、~/Library/Logs 的通用规则；必须让出专属规则的目录，并让出工具缓存根。
  /// 以后新增同类规则只需声明此属性，不依赖规则 id。
  let isGenericLibraryScan: Bool
  /// 最近修改过的条目视为正在使用
  public let minimumAge: TimeInterval
  public let requiredTool: String?
  /// 原生规则唯一入口：解析范围并生成本次计划；执行阶段不得重新拼接默认命令。
  let prepareTool: (@Sendable (CleanEnvironment) async throws -> ToolCachePlan)?
  /// 列出候选条目（顶层文件或目录）
  let locate: @Sendable (CleanEnvironment) throws -> [URL]

  init(
    id: String, category: CleanCategory, title: String, detail: String, symbol: String,
    selectedByDefault: Bool = true, policy: DeletionPolicy = .delete, previewOnly: Bool = false,
    blockingApps: [(bundleID: String, name: String)] = [], checksOwnerApp: Bool = false,
    requiresUnredirectedPath: Bool = false,
    cacheRelativePaths: [String] = [], blockingApplicationNames: [String] = [],
    isGenericLibraryScan: Bool = false,
    minimumAge: TimeInterval = 120, requiredTool: String? = nil,
    prepareTool: (@Sendable (CleanEnvironment) async throws -> ToolCachePlan)? = nil,
    locate: @escaping @Sendable (CleanEnvironment) throws -> [URL]
  ) {
    self.id = id
    self.category = category
    self.title = title
    self.detail = detail
    self.symbol = symbol
    self.selectedByDefault = selectedByDefault && !previewOnly
    self.previewOnly = previewOnly
    self.policy = policy
    self.blockingApps = blockingApps
    self.checksOwnerApp = checksOwnerApp
    self.requiresUnredirectedPath = requiresUnredirectedPath
    self.cacheRelativePaths = cacheRelativePaths
    self.blockingApplicationNames = blockingApplicationNames
    self.isGenericLibraryScan = isGenericLibraryScan
    self.minimumAge = minimumAge
    self.requiredTool = requiredTool
    self.prepareTool = prepareTool
    self.locate = locate
  }

  /// 原生规则不提供目录扫描回退；所有候选都必须来自 prepareTool 的本次计划。
  init(
    id: String, category: CleanCategory, title: String, detail: String, symbol: String,
    selectedByDefault: Bool = false, previewOnly: Bool = false,
    minimumAge: TimeInterval = 0, requiredTool: String,
    prepareTool: @escaping @Sendable (CleanEnvironment) async throws -> ToolCachePlan
  ) {
    self.init(
      id: id, category: category, title: title, detail: detail, symbol: symbol,
      selectedByDefault: selectedByDefault, previewOnly: previewOnly, minimumAge: minimumAge,
      requiredTool: requiredTool, prepareTool: prepareTool, locate: { _ in [] })
  }

  /// 包含应用的辅助进程；未确认的产品标识使用原生应用名称兜底。
  func runningApplication(identifiers: Set<String>, names: Set<String>) -> String? {
    if let app = blockingApps.first(where: { app in
      identifiers.contains { $0 == app.bundleID || $0.hasPrefix(app.bundleID + ".") }
    }) {
      return app.name
    }
    return blockingApplicationNames.first { name in
      names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
  }

  public var usesToolCleaner: Bool { prepareTool != nil }

  /// 执行时可能因对应应用正在运行而跳过条目；确认提示据此说明实际数量可能更少。
  public var mayBeSkippedWhileAppRunning: Bool {
    !blockingApps.isEmpty || !blockingApplicationNames.isEmpty || checksOwnerApp
  }

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
  /// 只保留多链接文件的身份和占用；单项大小不因其他候选是否被选中而变化。
  struct HardLink: Sendable, Hashable {
    let identity: String
    let size: UInt64
  }
  let hardLinks: [HardLink]

  public init(url: URL, size: UInt64) {
    self.init(url: url, size: size, hardLinks: [])
  }

  init(url: URL, size: UInt64, hardLinks: [HardLink]) {
    self.url = url
    self.size = size
    self.hardLinks = hardLinks
  }

  /// 选中项的占用并集；复用扫描时记录的硬链接证据，不重新读取文件系统。
  /// 手动构造的条目没有硬链接证据，保持原有大小语义。
  public static func totalSize(of items: [CleanItem]) -> UInt64 {
    var total = SizeTotal()
    for item in items { total.insert(item) }
    return total.bytes
  }

  /// 扫描合计与成功清理合计共用同一份身份账本，避免跨规则重复累计。
  struct SizeTotal {
    private(set) var bytes: UInt64 = 0
    private var hardLinks: [String: UInt64] = [:]

    mutating func insert(_ item: CleanItem) {
      var additional = item.size
      for link in item.hardLinks {
        if let counted = hardLinks[link.identity] {
          // 同一 inode 扫描期间可能变化；保留最大观测值，使合计与候选顺序无关。
          additional -= min(additional, min(counted, link.size))
          hardLinks[link.identity] = max(counted, link.size)
        } else {
          hardLinks[link.identity] = link.size
        }
      }
      let sum = bytes.addingReportingOverflow(additional)
      bytes = sum.overflow ? UInt64.max : sum.partialValue
    }
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
  public var interruption: ScanInterruption?

  public init(
    rule: CleanRule, items: [CleanItem], skippedCount: Int, blocked: SkipReason?,
    toolPreview: ToolCleanupPreview? = nil, skippedReasons: [SkipReason: Int] = [:],
    unreadableCount: Int = 0,
    toolCachePlan: ToolCachePlan? = nil, interruption: ScanInterruption? = nil
  ) {
    self.rule = rule
    self.items = items
    self.skippedCount = skippedCount
    self.blocked = blocked
    self.toolPreview = toolPreview
    self.skippedReasons = skippedReasons
    self.unreadableCount = unreadableCount
    self.toolCachePlan = toolCachePlan
    self.interruption = interruption
  }

  public var totalSize: UInt64 { toolPreview?.totalSize ?? CleanItem.totalSize(of: items) }
  public var isComplete: Bool {
    blocked == nil && unreadableCount == 0 && interruption == nil
  }
  /// 工具会整体清理其存储，预览不完整时不能按部分候选批准整个操作。
  public var isCleanable: Bool {
    !rule.previewOnly && blocked == nil && !items.isEmpty
      && (!rule.usesToolCleaner || isComplete)
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
  /// 工具中断或硬链接仍有其他持有者时，不能确认实际释放的空间。
  public var hasUncertainFreedBytes = false
  /// 工具报告与成功删除文件的扫描占用估计之和，不保证实际释放空间。
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
