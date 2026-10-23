import Foundation
import Darwin
import Localization

public enum CleanEngine {
  // MARK: 扫描

  /// 并发扫描所有规则，只读，不修改任何文件
  public static func scan(_ rules: [CleanRule], environment: CleanEnvironment) async -> [RuleScan] {
    let safety = SafetyGuard(home: environment.home)
    let budget = ScanBudget(limits: environment.scanLimits)
    return await withTaskGroup(of: (Int, RuleScan, Int).self) { group in
      // 为排队规则预留条目额度；完成后归还未用额度，局部耗尽不阻断其他规则。
      // 总条目、候选数及截止时间仍有界，同时最多两个目录遍历。
      var remainingEntries = environment.scanLimits.maxEntries
      var next = 0
      for (index, rule) in rules.prefix(2).enumerated() {
        var limits = environment.scanLimits
        limits.maxEntries = remainingEntries / (rules.count - index)
        remainingEntries -= limits.maxEntries
        let ruleBudget = ScanBudget(limits: limits, sharing: budget)
        group.addTask {
          let scan = await ScanBudget.$current.withValue(ruleBudget) {
            await scanRule(rule, environment: environment, safety: safety)
          }
          return (index, scan, ruleBudget.remainingEntries)
        }
        next += 1
      }
      var results = [(Int, RuleScan)]()
      for await result in group {
        results.append((result.0, result.1))
        remainingEntries += result.2
        if !Task.isCancelled, next < rules.count {
          let index = next
          let rule = rules[next]
          var limits = environment.scanLimits
          limits.maxEntries = remainingEntries / (rules.count - next)
          remainingEntries -= limits.maxEntries
          let ruleBudget = ScanBudget(limits: limits, sharing: budget)
          group.addTask {
            let scan = await ScanBudget.$current.withValue(ruleBudget) {
              await scanRule(rule, environment: environment, safety: safety)
            }
            return (index, scan, ruleBudget.remainingEntries)
          }
          next += 1
        }
      }
      let ordered = results.sorted { $0.0 < $1.0 }.map(\.1)
      let resolvedTools = Set(ordered.filter { !hasUnknownToolScope($0) }.map(\.id))
      let hasUnresolvedToolScope = rules.contains {
        $0.usesToolCleaner && !resolvedTools.contains($0.id)
      }
      let protected = protectingToolCaches(in: ordered, hasUnknownScope: hasUnresolvedToolScope)
      return removingOverlaps(protected)
    }
  }

  static func scanRule(_ rule: CleanRule, environment: CleanEnvironment, safety: SafetyGuard) async
    -> RuleScan
  {
    let budget = ScanBudget.current ?? ScanBudget(limits: environment.scanLimits)
    if let interruption = budget.interruption {
      return RuleScan(
        rule: rule, items: [], skippedCount: 0, blocked: nil, interruption: interruption)
    }
    let running = environment.runningBundleIdentifiers()
    if let app = rule.runningApplication(
      identifiers: running, names: environment.runningApplicationNames())
    {
      return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .appRunning(app))
    }
    var toolCachePlan: ToolCachePlan?
    if let prepareTool = rule.prepareTool {
      if let tool = rule.requiredTool, !environment.isToolAvailable(tool) {
        return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .toolUnavailable(tool))
      }
      do {
        let plan = try await withThrowingTaskGroup(of: ToolCachePlan.self) { group in
          group.addTask { try await prepareTool(environment) }
          group.addTask {
            try await ContinuousClock().sleep(until: budget.deadline)
            throw ScanInterruption.timeLimit
          }
          defer { group.cancelAll() }
          guard let plan = try await group.next() else { throw CancellationError() }
          return plan
        }
        toolCachePlan = plan
        try budget.check()
        if !environment.excludedPaths.isEmpty {
          // Homebrew 等全局操作无法锁定全部删除路径；有保留要求时不能凭默认目录放行。
          guard plan.hasBoundedScope else { throw ToolCachePlanError.unknownScope }
          if plan.roots.contains(where: {
            CleanupExclusions.overlaps($0, paths: environment.excludedPaths)
          }) {
            return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .excluded)
          }
        }
      } catch {
        if let interruption = Self.interruption(for: error) ?? budget.interruption {
          return RuleScan(
            rule: rule, items: [], skippedCount: 0, blocked: nil,
            toolCachePlan: toolCachePlan, interruption: interruption)
        }
        return RuleScan(
          rule: rule, items: [], skippedCount: 0,
          blocked: .previewFailed(String(error.localizedDescription.prefix(1024))),
          toolCachePlan: toolCachePlan)
      }
    }
    if let preview = toolCachePlan?.preview {
      do {
        for item in preview.items {
          try budget.visitCandidate(item.url.standardizedFileURL.path)
        }
        try budget.check()
        return RuleScan(
          rule: rule, items: preview.items, skippedCount: 0, blocked: nil,
          toolPreview: preview, toolCachePlan: toolCachePlan)
      } catch {
        return RuleScan(
          rule: rule, items: [], skippedCount: 0, blocked: nil,
          toolCachePlan: toolCachePlan, interruption: Self.interruption(for: error))
      }
    }

    let candidates: [URL]
    do {
      let located =
        try toolCachePlan?.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        ?? rule.locate(environment)
      candidates = try standardizedCandidates(located, budget: budget)
    } catch {
      if let interruption = Self.interruption(for: error) ?? budget.interruption {
        return RuleScan(
          rule: rule, items: [], skippedCount: 0, blocked: nil,
          toolCachePlan: toolCachePlan, interruption: interruption)
      }
      let failure = error as NSError
      let permission =
        error is CleanerAccessError
        || (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError)
        || (failure.domain == NSPOSIXErrorDomain
          && [Int(EPERM), Int(EACCES)].contains(failure.code))
      return RuleScan(
        rule: rule, items: [], skippedCount: 0,
        blocked: permission
          ? .needsFullDiskAccess : .previewFailed(String(error.localizedDescription.prefix(1024))),
        toolCachePlan: toolCachePlan)
    }
    if !candidates.isEmpty, let tool = rule.requiredTool, !environment.isToolAvailable(tool) {
      return RuleScan(
        rule: rule, items: [], skippedCount: 0, blocked: .toolUnavailable(tool),
        toolCachePlan: toolCachePlan)
    }

    var items: [CleanItem] = []
    var skipped = 0
    var reasons: [SkipReason: Int] = [:]
    var unreadable = 0
    var interruption: ScanInterruption?
    var accepted = PathIndex()
    for url in candidates {
      do {
        try budget.check()
      } catch {
        interruption = Self.interruption(for: error)
        break
      }
      // 工具托管的缓存由工具自身处理锁与内部目录；这里的路径只用于只读计量，不能套用
      // “应用数据保护词”过滤，否则名为 xstats 等普通包会被误报为正在使用。
      let reason =
        rule.usesToolCleaner
        ? nil
        : skipReason(
          for: url, rule: rule, running: running, environment: environment, safety: safety)
      if let stopped = budget.interruption {
        interruption = stopped
        break
      }
      if let reason {
        skipped += 1
        reasons[reason, default: 0] += 1
        continue
      }
      // 先保护过滤再消除父子重叠，不让不安全父目录遮住可计量的子项。
      guard !accepted.overlaps(url.path) else { continue }
      accepted.insert(url.path)
      do {
        let item = try measureAllocatedSize(of: url, checkCancellation: { try budget.visit() })
        try budget.check()
        if item.size > 0 { items.append(item) }
      } catch let limit as ScanInterruption {
        interruption = limit
        break
      } catch is CancellationError {
        interruption = .cancelled
        break
      } catch { unreadable += 1 }
    }
    interruption = interruption ?? budget.interruption
    items.sort { $0.size == $1.size ? $0.url.path < $1.url.path : $0.size > $1.size }
    return RuleScan(
      rule: rule, items: items, skippedCount: skipped, blocked: nil,
      skippedReasons: reasons, unreadableCount: unreadable, toolCachePlan: toolCachePlan,
      interruption: interruption)
  }

  private static func interruption(for error: Error) -> ScanInterruption? {
    if error is CancellationError || Task.isCancelled { return .cancelled }
    if let interruption = error as? ScanInterruption { return interruption }
    if let toolError = error as? ToolExecutionError, case .timedOut = toolError {
      return .timeLimit
    }
    return nil
  }

  private static func standardizedCandidates(_ urls: [URL], budget: ScanBudget) throws -> [URL] {
    var paths = Set<String>()
    var candidates: [URL] = []
    for url in urls {
      let candidate = url.standardizedFileURL
      try budget.visitCandidate(candidate.path)
      if paths.insert(candidate.path).inserted { candidates.append(candidate) }
    }
    try budget.check()
    return candidates.sorted {
      $0.pathComponents.count == $1.pathComponents.count
        ? $0.path < $1.path : $0.pathComponents.count < $1.pathComponents.count
    }
  }

  /// 路径集合与已登记路径的祖先集合，按路径深度查询双向重叠，不遍历历史候选数组。
  private struct PathIndex {
    private var roots = Set<String>()
    private var ancestors = Set<String>()

    mutating func insert(_ path: String) {
      guard roots.insert(path).inserted else { return }
      var parent = URL(fileURLWithPath: path)
      while parent.path != "/" {
        parent.deleteLastPathComponent()
        ancestors.insert(parent.path)
      }
    }

    func overlaps(_ path: String) -> Bool {
      if roots.contains(path) || ancestors.contains(path) { return true }
      var parent = URL(fileURLWithPath: path)
      while parent.path != "/" {
        parent.deleteLastPathComponent()
        if roots.contains(parent.path) { return true }
      }
      return false
    }
  }

  private static func replacingItems(
    in scan: RuleScan, with items: [CleanItem], blocked: SkipReason? = nil
  ) -> RuleScan {
    var result = RuleScan(
      rule: scan.rule, items: items,
      skippedCount: scan.skippedCount + scan.items.count - items.count,
      blocked: scan.blocked ?? blocked, toolPreview: scan.toolPreview,
      skippedReasons: scan.skippedReasons, unreadableCount: scan.unreadableCount,
      toolCachePlan: scan.toolCachePlan, interruption: scan.interruption)
    let removed = scan.items.count - items.count
    if removed > 0 { result.skippedReasons[.protected, default: 0] += removed }
    return result
  }

  private static func hasUnknownToolScope(_ scan: RuleScan) -> Bool {
    guard scan.rule.usesToolCleaner, scan.toolCachePlan == nil else { return false }
    // 仅豁免扫描时已明确确认缺失的工具；中断、未调度和解析失败仍不能接管自定义路径。
    if scan.interruption == nil, let tool = scan.rule.requiredTool,
      scan.blocked == .toolUnavailable(tool)
    {
      return false
    }
    return true
  }

  /// 工具范围未知时保留计量证据，但不批准通用规则接管；扫描与执行入口共用此保护。
  private static func protectingToolCaches(
    in scans: [RuleScan], hasUnknownScope: Bool
  ) -> [RuleScan] {
    var roots = PathIndex()
    for root in scans.compactMap(\.toolCachePlan).flatMap(\.roots) {
      roots.insert(root.standardizedFileURL.path)
    }
    let blocked: SkipReason? =
      hasUnknownScope ? .previewFailed(ToolCachePlanError.unknownScope.localizedDescription) : nil
    return scans.map { scan in
      guard scan.rule.isGenericLibraryScan else { return scan }
      let items = scan.items.filter { !roots.overlaps($0.url.standardizedFileURL.path) }
      return replacingItems(in: scan, with: items, blocked: blocked)
    }
  }

  /// 预览对象先保留归属，再处理专属规则与通用规则，避免通用父目录吞掉仅预览子项。
  private static func removingOverlaps(_ scans: [RuleScan]) -> [RuleScan] {
    let candidates = scans.enumerated().flatMap { index, scan in
      scan.rule.usesToolCleaner ? [] : scan.items.map { (index, $0) }
    }.sorted { left, right in
      let a = scans[left.0].rule
      let b = scans[right.0].rule
      if a.previewOnly != b.previewOnly { return a.previewOnly }
      if a.isGenericLibraryScan != b.isGenericLibraryScan { return !a.isGenericLibraryScan }
      let leftPath = left.1.url.standardizedFileURL.path
      let rightPath = right.1.url.standardizedFileURL.path
      if leftPath != rightPath {
        if left.1.url.pathComponents.count != right.1.url.pathComponents.count {
          return left.1.url.pathComponents.count < right.1.url.pathComponents.count
        }
        return leftPath < rightPath
      }
      return left.0 < right.0
    }
    var paths = PathIndex()
    for root in scans.compactMap(\.toolCachePlan).flatMap(\.roots) {
      paths.insert(root.standardizedFileURL.path)
    }
    var kept: [Int: Set<String>] = [:]
    for (index, item) in candidates {
      let path = item.url.standardizedFileURL.path
      guard !paths.overlaps(path) else { continue }
      paths.insert(path)
      kept[index, default: []].insert(item.id)
    }
    return scans.enumerated().map { index, scan in
      guard !scan.rule.usesToolCleaner else { return scan }
      return replacingItems(
        in: scan, with: scan.items.filter { kept[index]?.contains($0.id) == true })
    }
  }

  static func skipReason(
    for url: URL, rule: CleanRule, running: Set<String>,
    environment: CleanEnvironment, safety: SafetyGuard
  ) -> SkipReason? {
    if CleanupExclusions.overlaps(url, paths: environment.excludedPaths) { return .excluded }
    if !rule.cacheRelativePaths.isEmpty {
      let allowed = rule.cacheRelativePaths.map {
        URL(fileURLWithPath: environment.home).appendingPathComponent($0).standardizedFileURL.path
      }
      guard allowed.contains(url.standardizedFileURL.path) else { return .protected }
    }
    guard (try? safety.validate(url, additionalCachePaths: rule.cacheRelativePaths)) != nil else {
      return .protected
    }
    // 专属目录即使不存在、应用运行中或未被勾选，也不允许通用规则接管。
    if rule.isGenericLibraryScan {
      let roots = (ApplicationCacheCatalog.reservedRoots + RuleCatalog.previewOnlyReservedPaths).map
      {
        URL(fileURLWithPath: environment.home).appendingPathComponent($0).path
      }
      if CleanupExclusions.overlaps(url, paths: roots) { return .protected }
      guard let cargoRoots = try? DeveloperCleanupCatalog.rustStorageRoots(environment: environment)
      else { return .protected }
      if CleanupExclusions.overlaps(url, paths: cargoRoots.map(\.path)) { return .protected }
    }
    if rule.requiresUnredirectedPath,
      !AppUninstaller.isUnredirected(url, home: environment.home)
    {
      return .protected
    }

    if rule.checksOwnerApp,
      let owner = owningApp(of: url, running: running, names: environment.runningApplicationNames())
    {
      return .appRunning(owner)
    }
    if rule.minimumAge > 0, isRecentlyModified(url, rule: rule, now: environment.now()) {
      return .recentlyModified
    }
    return nil
  }

  /// 应用缓存规则向下检查的最大层数与条目数；Chromium 缓存形如 Cache/Cache_Data/f_xxxxxx。
  static let recentWriteDepthLimit = 3
  static let recentWriteEntryLimit = 2_000

  /// 目录自身 mtime 只反映直接子项的增删，应用缓存规则额外有界地检查更深处的最近写入。
  /// 达到条目上限仍未发现最近写入时按“未修改”处理：运行中应用已由进程标识与名称拦截，
  /// 保守地拒绝大缓存会让规则永远无法执行。取消时同样提前返回，调用方在删除前再核对取消状态。
  static func isRecentlyModified(_ url: URL, rule: CleanRule, now: Date) -> Bool {
    // 扫描 URL 可能缓存资源属性；执行前必须从文件系统重新读取修改时间。
    let fresh = URL(fileURLWithPath: url.path)
    let key = URLResourceKey.contentModificationDateKey
    if let modified = try? fresh.resourceValues(forKeys: [key]).contentModificationDate,
      now.timeIntervalSince(modified) < rule.minimumAge
    {
      return true
    }
    guard !rule.cacheRelativePaths.isEmpty,
      let enumerator = FileManager.default.enumerator(
        at: fresh, includingPropertiesForKeys: [key], options: [.skipsPackageDescendants])
    else { return false }
    var visited = 0
    while let entry = enumerator.nextObject() as? URL {
      visited += 1
      if visited > recentWriteEntryLimit || Task.isCancelled { return false }
      if let budget = ScanBudget.current {
        do { try budget.visit() } catch { return false }
      }
      if let modified = try? entry.resourceValues(forKeys: [key]).contentModificationDate,
        now.timeIntervalSince(modified) < rule.minimumAge
      {
        return true
      }
      if enumerator.level >= recentWriteDepthLimit { enumerator.skipDescendants() }
    }
    return false
  }

  /// 同时识别友好名称、已登记的目录别名，以及反向域名的应用与辅助进程。
  static func owningApp(of url: URL, running: Set<String>, names: Set<String> = []) -> String? {
    let name = url.lastPathComponent
    if let owner = ApplicationCacheCatalog.runningOwner(
      directory: name, identifiers: running, names: names)
    {
      return owner
    }
    if let owner = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
      return owner
    }
    guard name.split(separator: ".").count >= 3 else { return nil }
    return running.sorted().first {
      name == $0 || name.hasPrefix($0 + ".") || $0.hasPrefix(name + ".")
    }
  }

  /// 展示应用体积。只解析根上的符号链接，且目标本身必须仍是 .app；内部链接不跟随。
  /// 清理和卸载继续使用 `scanAllocatedSize`，不能把链接目标当成可删除内容。
  public static func bundleAllocatedSize(
    of url: URL,
    checkCancellation: () throws -> Void = { try Task.checkCancellation() }
  ) throws -> UInt64 {
    try checkCancellation()
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink == true else {
      return try scanAllocatedSize(of: url, checkCancellation: checkCancellation)
    }
    let target = url.resolvingSymlinksInPath()
    guard target.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return 0 }
    return try scanAllocatedSize(of: target, checkCancellation: checkCancellation)
  }

  /// 实际占用的磁盘空间；不跟随符号链接
  public static func allocatedSize(of url: URL) -> UInt64 {
    // 保持同步调用方的完整计量语义；可取消操作使用 throwing 入口，不能把部分结果当完整大小。
    (try? scanAllocatedSize(of: url, checkCancellation: {})) ?? 0
  }

  /// 完整体积计量，遍历期间响应取消；取消时抛错，不返回部分大小。
  public static func scanAllocatedSize(
    of url: URL,
    checkCancellation: () throws -> Void = { try Task.checkCancellation() }
  ) throws -> UInt64 {
    try measureAllocatedSize(of: url, checkCancellation: checkCancellation).size
  }

  private static func measureAllocatedSize(
    of url: URL, checkCancellation: () throws -> Void
  ) throws -> CleanItem {
    try checkCancellation()
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    let values = try url.resourceValues(forKeys: Set(keys))
    guard values.isSymbolicLink != true else { return CleanItem(url: url, size: 0) }
    if values.isRegularFile == true {
      guard let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize, size >= 0 else {
        throw CocoaError(.fileReadUnknown)
      }
      let link = try hardLink(of: url, size: UInt64(size))
      return CleanItem(url: url, size: UInt64(size), hardLinks: link.map { [$0] } ?? [])
    }
    var traversalError: (any Error)?
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: keys, options: [],
        errorHandler: { _, error in
          traversalError = error
          return false
        })
    else {
      throw CocoaError(.fileReadUnknown)
    }
    var total: UInt64 = 0
    var hardLinks: [String: CleanItem.HardLink] = [:]
    while let file = enumerator.nextObject() as? URL {
      try checkCancellation()
      let fileValues = try file.resourceValues(forKeys: Set(keys))
      guard fileValues.isRegularFile == true, fileValues.isSymbolicLink != true else { continue }
      guard let size = fileValues.totalFileAllocatedSize ?? fileValues.fileAllocatedSize, size >= 0
      else { throw CocoaError(.fileReadUnknown) }
      if let link = try hardLink(of: file, size: UInt64(size)) {
        guard hardLinks[link.identity] == nil else { continue }
        hardLinks[link.identity] = link
      }
      let sum = total.addingReportingOverflow(UInt64(size))
      guard !sum.overflow else { throw CocoaError(.fileReadUnknown) }
      total = sum.partialValue
    }
    if let traversalError { throw traversalError }
    return CleanItem(
      url: url, size: total, hardLinks: hardLinks.values.sorted { $0.identity < $1.identity })
  }

  private static func hardLink(of url: URL, size: UInt64) throws -> CleanItem.HardLink? {
    var information = stat()
    guard url.path.withCString({ lstat($0, &information) }) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard information.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
    guard information.st_nlink > 1 else { return nil }
    return CleanItem.HardLink(identity: "\(information.st_dev):\(information.st_ino)", size: size)
  }

  // MARK: 清理

  /// 单条规则在一次清理中的进度上下文；跨子阶段复用同一份计数基准。
  private struct RuleProgress {
    let scan: RuleScan
    let ruleIndex: Int
    let ruleCount: Int
    let completedBeforeRule: Int
    let currentRuleTotal: Int
    let totalSteps: Int
    let progressInterval: Int
    let startedAt: Date

    func snapshot(completed: Int, toolScannedBytes: UInt64?) -> CleanProgress {
      CleanProgress(
        completed: completed, total: totalSteps, currentRule: scan.rule.title,
        ruleNumber: ruleIndex + 1, ruleCount: ruleCount,
        currentRuleCompleted: completed - completedBeforeRule,
        currentRuleTotal: currentRuleTotal, currentRuleStartedAt: startedAt,
        toolScannedBytes: toolScannedBytes)
    }
  }

  /// 清理选中规则的扫描结果。执行前逐项重新校验：扫描到执行之间应用可能已经启动
  public static func clean(
    _ scans: [RuleScan], selected: Set<String>, preferTrash: Bool,
    environment: CleanEnvironment, log: CleanLog? = CleanLog(),
    refreshRunningApps: (@Sendable () async -> Set<String>)? = nil,
    refreshRunningApplicationNames: (@Sendable () async -> Set<String>)? = nil,
    onProgress: (@Sendable (CleanProgress) async -> Void)? = nil
  ) async -> CleanReport {
    let safety = SafetyGuard(home: environment.home)
    var report = CleanReport()
    var deletedFiles = CleanItem.SizeTotal()
    var trashedFiles = CleanItem.SizeTotal()
    let protected = protectingToolCaches(
      in: scans, hasUnknownScope: scans.contains { hasUnknownToolScope($0) })
    let selectedScans = protected.filter { selected.contains($0.id) && $0.isCleanable }
    let totalSteps = selectedScans.reduce(0) { $0 + ($1.rule.usesToolCleaner ? 1 : $1.items.count) }
    let progressInterval = max(1, (totalSteps + 99) / 100)
    var completedSteps = 0

    for (ruleIndex, scan) in selectedScans.enumerated() {
      if Task.isCancelled {
        report.wasCancelled = true
        return report
      }
      let progress = RuleProgress(
        scan: scan, ruleIndex: ruleIndex, ruleCount: selectedScans.count,
        completedBeforeRule: completedSteps,
        currentRuleTotal: scan.rule.usesToolCleaner ? 1 : scan.items.count,
        totalSteps: totalSteps, progressInterval: progressInterval, startedAt: Date())
      let currentProgress = {
        progress.snapshot(
          completed: completedSteps,
          toolScannedBytes: scan.rule.usesToolCleaner ? scan.totalSize : nil)
      }
      await onProgress?(currentProgress())
      let running = await refreshRunningApps?() ?? environment.runningBundleIdentifiers()
      if scan.rule.usesToolCleaner, !environment.excludedPaths.isEmpty,
        scan.toolCachePlan?.hasBoundedScope != true
      {
        report.failures.append(ToolCachePlanError.unknownScope.localizedDescription)
        completedSteps += progress.currentRuleTotal
        await onProgress?(currentProgress())
        continue
      }
      if scan.rule.usesToolCleaner,
        ((scan.toolCachePlan?.roots ?? []) + scan.items.map(\.url)).contains(where: {
          CleanupExclusions.overlaps($0, paths: environment.excludedPaths)
        })
      {
        report.skippedCount += scan.items.count
        completedSteps += progress.currentRuleTotal
        await onProgress?(currentProgress())
        continue
      }
      if scan.rule.runningApplication(
        identifiers: running,
        names: await refreshRunningApplicationNames?() ?? environment.runningApplicationNames())
        != nil
      {
        report.skippedCount += scan.items.count
        completedSteps += progress.currentRuleTotal
        await onProgress?(currentProgress())
        continue
      }
      if scan.rule.usesToolCleaner {
        let cancelled = await cleanWithTool(
          scan, environment: environment, log: log, report: &report)
        if cancelled { return report }
        completedSteps += 1
        await onProgress?(currentProgress())
        continue
      }
      // 工具预览中的路径不受文件规则白名单约束，因此绝不能回退到手动删除。
      guard scan.toolCachePlan == nil && scan.toolPreview == nil else {
        completedSteps += scan.items.count
        await onProgress?(currentProgress())
        continue
      }
      let useTrash = !scan.rule.deletesPermanently(preferTrash: preferTrash)
      let cancelled = await cleanManually(
        scan, useTrash: useTrash, running: running, environment: environment,
        safety: safety, log: log, refreshRunningApps: refreshRunningApps,
        refreshRunningApplicationNames: refreshRunningApplicationNames,
        progress: progress, onProgress: onProgress,
        report: &report, completedSteps: &completedSteps,
        deletedFiles: &deletedFiles, trashedFiles: &trashedFiles)
      if cancelled { return report }
    }
    return report
  }

  /// 工具托管清理路径：执行外部清理工具，或在工具不产出报告时按剩余体积估算释放量。
  /// 取消只会在该规则内发生，返回 true 时调用方必须立即结束整次清理。
  private static func cleanWithTool(
    _ scan: RuleScan, environment: CleanEnvironment, log: CleanLog?,
    report: inout CleanReport
  ) async -> Bool {
    guard let plan = scan.toolCachePlan else {
      report.failures.append(ToolCachePlanError.unknownScope.localizedDescription)
      return false
    }
    if let tool = scan.rule.requiredTool, !environment.isToolAvailable(tool) {
      report.failures.append(tr("\(scan.rule.title)：未找到 \(tool)，无法安全清理"))
      return false
    }
    do {
      let toolReport = try await plan.execute(in: environment)
      guard let toolReport else {
        var remainingItems: [CleanItem] = []
        if scan.items.contains(where: { !$0.hardLinks.isEmpty }) {
          report.hasUncertainFreedBytes = true
        }
        for item in scan.items {
          let remaining: CleanItem
          do {
            remaining = try measureAllocatedSize(
              of: item.url, checkCancellation: { try Task.checkCancellation() })
          } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
          { remaining = CleanItem(url: item.url, size: 0) } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
          { remaining = CleanItem(url: item.url, size: 0) }
          remainingItems.append(remaining)
          if !remaining.hardLinks.isEmpty { report.hasUncertainFreedBytes = true }
          log?.record(item: item, rule: scan.rule, action: "tool", detail: scan.rule.requiredTool)
          guard remaining.size < item.size else { continue }
          report.removedCount += 1
        }
        let before = CleanItem.totalSize(of: scan.items)
        let after = CleanItem.totalSize(of: remainingItems)
        if after < before { report.freedBytes += before - after }
        return false
      }
      report.freedBytes += toolReport.freedBytes
      report.removedCount += toolReport.removedCount
      report.skippedCount += toolReport.skippedCount
      report.failures += toolReport.failures
      report.trashedBytes += toolReport.trashedBytes
      report.wasCancelled = toolReport.wasCancelled
      report.hasUncertainFreedBytes =
        report.hasUncertainFreedBytes || toolReport.hasUncertainFreedBytes
      log?.recordTool(rule: scan.rule, report: toolReport)
      return report.wasCancelled
    } catch {
      // 外部命令可能已删除部分内容，失败或取消后都无法从扫描结果确认实际释放量。
      report.hasUncertainFreedBytes = true
      log?.recordToolInterruption(
        rule: scan.rule, error: error,
        cancelled: error is CancellationError || Task.isCancelled)
      guard error is CancellationError || Task.isCancelled else {
        report.failures.append(tr("\(scan.rule.title)：\(error.localizedDescription)"))
        return false
      }
      report.wasCancelled = true
      return true
    }
  }

  /// 手动文件清理路径：逐项重新核对运行中的应用与保护规则后，移入废纸篓或直接删除。
  /// 取消时整条规则的剩余条目一律中止，调用方须返回已有 report，不得继续下一条规则。
  private static func cleanManually(
    _ scan: RuleScan, useTrash: Bool, running: Set<String>,
    environment: CleanEnvironment, safety: SafetyGuard, log: CleanLog?,
    refreshRunningApps: (@Sendable () async -> Set<String>)?,
    refreshRunningApplicationNames: (@Sendable () async -> Set<String>)?,
    progress: RuleProgress, onProgress: (@Sendable (CleanProgress) async -> Void)?,
    report: inout CleanReport, completedSteps: inout Int,
    deletedFiles: inout CleanItem.SizeTotal, trashedFiles: inout CleanItem.SizeTotal
  ) async -> Bool {
    var running = running
    for item in scan.items {
      // 每个目录候选操作前刷新；不是逐个缓存文件刷新，避免大目录清理期间沿用旧快照。
      running = await refreshRunningApps?() ?? environment.runningBundleIdentifiers()
      if Task.isCancelled {
        report.wasCancelled = true
        return true
      }
      let names = await refreshRunningApplicationNames?() ?? environment.runningApplicationNames()
      if Task.isCancelled {
        report.wasCancelled = true
        return true
      }
      var currentEnvironment = environment
      currentEnvironment.runningApplicationNames = { names }
      let blockingApp = scan.rule.runningApplication(identifiers: running, names: names)
      var skip =
        blockingApp.map({ SkipReason.appRunning($0) })
        ?? skipReason(
          for: item.url, rule: scan.rule, running: running,
          environment: currentEnvironment, safety: safety)
      if skip == nil {
        // skipReason 末段的有界遍历可能耗时，取消在此生效，不能带着取消继续删除。
        if Task.isCancelled {
          report.wasCancelled = true
          return true
        }
        // 紧贴删除前的最后一次复检，缩小符号链接被替换的窗口。残余窗口：复检与
        // removeItem/trashItem 之间仍是按路径操作；彻底关闭需要 openat/unlinkat 逐级
        // O_NOFOLLOW。能替换这些目录的进程已具备同用户对其的完整写权限，微秒级窗口可接受。
        if (try? safety.validate(item.url, additionalCachePaths: scan.rule.cacheRelativePaths))
          == nil
          || (scan.rule.requiresUnredirectedPath
            && !AppUninstaller.isUnredirected(item.url, home: environment.home))
        {
          skip = .protected
        }
      }
      if let reason = skip {
        report.skippedCount += 1
        log?.record(item: item, rule: scan.rule, action: "skip", detail: reason.title)
        completedSteps += 1
        if completedSteps % progress.progressInterval == 0
          || completedSteps - progress.completedBeforeRule == progress.currentRuleTotal
        {
          await onProgress?(progress.snapshot(completed: completedSteps, toolScannedBytes: nil))
        }
        continue
      }
      do {
        if useTrash {
          try environment.trash(item.url)
          let before = trashedFiles.bytes
          trashedFiles.insert(item)
          report.trashedBytes += trashedFiles.bytes - before
        } else {
          try FileManager.default.removeItem(at: item.url)
          let before = deletedFiles.bytes
          deletedFiles.insert(item)
          report.freedBytes += deletedFiles.bytes - before
          if !item.hardLinks.isEmpty { report.hasUncertainFreedBytes = true }
        }
        report.removedCount += 1
        log?.record(item: item, rule: scan.rule, action: useTrash ? "trash" : "delete", detail: nil)
      } catch {
        report.failures.append(tr("\(item.url.lastPathComponent)：\(error.localizedDescription)"))
        log?.record(item: item, rule: scan.rule, action: "fail", detail: error.localizedDescription)
      }
      completedSteps += 1
      if completedSteps % progress.progressInterval == 0
        || completedSteps - progress.completedBeforeRule == progress.currentRuleTotal
      {
        await onProgress?(progress.snapshot(completed: completedSteps, toolScannedBytes: nil))
      }
    }
    return false
  }
}

/// 清理操作日志：~/Library/Logs/XStats/cleanup.log，每行一条 JSON
public struct CleanLog: Sendable {
  static let maximumBytes = 1024 * 1024
  private static let writeLock = NSLock()
  public let url: URL

  public init(
    url: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/XStats/cleanup.log")
  ) {
    self.url = url
  }

  func record(item: CleanItem, rule: CleanRule, action: String, detail: String?) {
    record(url: item.url, ruleID: rule.id, bytes: item.size, action: action, detail: detail)
  }

  func record(url: URL, ruleID: String, bytes: UInt64, action: String, detail: String?) {
    var entry: [String: Any] = [
      "time": ISO8601DateFormatter().string(from: Date()),
      "rule": ruleID,
      "action": action,
      "path": url.path,
      "bytes": bytes,
    ]
    if let detail { entry["detail"] = detail }
    write(entry)
  }

  /// 原生命令只报告汇总结果；扫描候选不能作为实际删除记录。
  func recordTool(rule: CleanRule, report: CleanReport) {
    var entry: [String: Any] = [
      "time": ISO8601DateFormatter().string(from: Date()),
      "rule": rule.id,
      "action": "tool",
      "bytes": report.freedBytes,
      "removedCount": report.removedCount,
    ]
    if let tool = rule.requiredTool { entry["detail"] = tool }
    write(entry)
  }

  func recordToolInterruption(rule: CleanRule, error: Error, cancelled: Bool) {
    var entry: [String: Any] = [
      "time": ISO8601DateFormatter().string(from: Date()),
      "rule": rule.id,
      "action": cancelled ? "cancel" : "fail",
    ]
    if let tool = rule.requiredTool { entry["tool"] = tool }
    if !cancelled { entry["detail"] = error.localizedDescription }
    write(entry)
  }

  private func write(_ entry: [String: Any]) {
    // 单条异常错误文本不能撑大文件；按 Unicode scalar 截断，兼顾 UTF-8 和超长组合字符，JSON 仍保持完整。
    let boundedEntry = entry.mapValues { value -> Any in
      if let text = value as? String { return String(text.unicodeScalars.prefix(4096)) }
      return value
    }
    guard
      var data = try? JSONSerialization.data(withJSONObject: boundedEntry, options: [.sortedKeys])
    else { return }
    data.append(0x0A)

    // 多个清理入口共用日志，压缩和追加必须串行，避免丢失并发写入。
    Self.writeLock.withLock {
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
          try data.write(to: url, options: .atomic)
          return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size + UInt64(data.count) > UInt64(Self.maximumBytes) {
          // 仅在达到上限时读取半个窗口；丢弃首条残行，兼容旧版本遗留的大文件。
          let retainedBytes = min(size, UInt64(Self.maximumBytes / 2))
          try handle.seek(toOffset: size - retainedBytes)
          var tail = try handle.read(upToCount: Int(retainedBytes)) ?? Data()
          if size > retainedBytes {
            if let newline = tail.firstIndex(of: 0x0A) {
              tail = Data(tail.suffix(from: tail.index(after: newline)))
            } else {
              tail.removeAll()
            }
          }
          // 不把新增 JSON 接到意外中断的旧记录上。
          if tail.last != 0x0A {
            if let newline = tail.lastIndex(of: 0x0A) {
              tail = Data(tail.prefix(through: newline))
            } else {
              tail.removeAll()
            }
          }
          tail.append(data)
          try tail.write(to: url, options: .atomic)
        } else {
          try handle.write(contentsOf: data)
        }
      } catch {
        // 清理日志是尽力写入；磁盘或权限错误不能改变清理结果。
      }
    }
  }
}
