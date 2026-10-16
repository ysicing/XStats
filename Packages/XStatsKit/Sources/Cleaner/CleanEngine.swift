import Foundation
import Localization

public enum CleanEngine {
  // MARK: 扫描

  /// 并发扫描所有规则，只读，不修改任何文件
  public static func scan(_ rules: [CleanRule], environment: CleanEnvironment) async -> [RuleScan] {
    let safety = SafetyGuard(home: environment.home)
    return await withTaskGroup(of: (Int, RuleScan).self) { group in
      // 同时最多四个目录遍历，避免多条规则一起占满磁盘；取消后不继续启动新规则。
      var next = 0
      for (index, rule) in rules.prefix(4).enumerated() {
        group.addTask { (index, await scanRule(rule, environment: environment, safety: safety)) }
        next += 1
      }
      var results = [(Int, RuleScan)]()
      for await result in group {
        results.append(result)
        if !Task.isCancelled, next < rules.count {
          let index = next
          let rule = rules[next]
          group.addTask { (index, await scanRule(rule, environment: environment, safety: safety)) }
          next += 1
        }
      }
      let ordered = results.sorted { $0.0 < $1.0 }.map(\.1)
      let toolRoots = ordered.compactMap(\.toolCachePlan).flatMap(\.roots)
      // 工具的自定义缓存可能也位于通用 Caches/Logs 下，不能重复计量或先被直接删除。
      return ordered.map { scan in
        guard ["system.caches", "system.logs"].contains(scan.id) else { return scan }
        let items = scan.items.filter { item in
          !toolRoots.contains { CleanupExclusions.overlaps(item.url, paths: [$0.path]) }
        }
        return RuleScan(
          rule: scan.rule, items: items,
          skippedCount: scan.skippedCount + scan.items.count - items.count,
          blocked: scan.blocked, skippedReasons: scan.skippedReasons,
          unreadableCount: scan.unreadableCount)
      }
    }
  }

  static func scanRule(_ rule: CleanRule, environment: CleanEnvironment, safety: SafetyGuard) async
    -> RuleScan
  {
    let running = environment.runningBundleIdentifiers()
    if let app = rule.blockingApps.first(where: { running.contains($0.bundleID) }) {
      return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .appRunning(app.name))
    }
    var toolCachePlan: ToolCachePlan?
    if let prepareTool = rule.prepareTool {
      if let tool = rule.requiredTool, !environment.isToolAvailable(tool) {
        return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .toolUnavailable(tool))
      }
      do {
        let plan = try await prepareTool(environment)
        toolCachePlan = plan
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
        return RuleScan(
          rule: rule, items: [], skippedCount: 0,
          blocked: .previewFailed(String(error.localizedDescription.prefix(1024))))
      }
    }
    if let preview = toolCachePlan?.preview {
      return RuleScan(
        rule: rule, items: preview.items, skippedCount: 0, blocked: nil,
        toolPreview: preview, toolCachePlan: toolCachePlan)
    }

    let candidates: [URL]
    do {
      candidates =
        try toolCachePlan?.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        ?? rule.locate(environment)
    } catch {
      let failure = error as NSError
      let permission =
        error is CleanerAccessError
        || (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError)
        || (failure.domain == NSPOSIXErrorDomain
          && [Int(EPERM), Int(EACCES)].contains(failure.code))
      return RuleScan(
        rule: rule, items: [], skippedCount: 0,
        blocked: permission
          ? .needsFullDiskAccess : .previewFailed(String(error.localizedDescription.prefix(1024))))
    }
    if !candidates.isEmpty, let tool = rule.requiredTool, !environment.isToolAvailable(tool) {
      return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .toolUnavailable(tool))
    }

    var items: [CleanItem] = []
    var skipped = 0
    var reasons: [SkipReason: Int] = [:]
    var unreadable = 0
    for url in candidates {
      if Task.isCancelled { break }
      // 工具托管的缓存由工具自身处理锁与内部目录；这里的路径只用于只读计量，不能套用
      // “应用数据保护词”过滤，否则名为 xstats 等普通包会被误报为正在使用。
      if !rule.usesToolCleaner,
        let reason = skipReason(
          for: url, rule: rule, running: running, environment: environment, safety: safety)
      {
        skipped += 1
        reasons[reason, default: 0] += 1
        continue
      }
      do {
        let size = try scanAllocatedSize(of: url)
        if size > 0 { items.append(CleanItem(url: url, size: size)) }
      } catch is CancellationError { break } catch { unreadable += 1 }
    }
    items.sort { $0.size > $1.size }
    return RuleScan(
      rule: rule, items: items, skippedCount: skipped, blocked: nil,
      skippedReasons: reasons, unreadableCount: unreadable, toolCachePlan: toolCachePlan)
  }

  static func skipReason(
    for url: URL, rule: CleanRule, running: Set<String>,
    environment: CleanEnvironment, safety: SafetyGuard
  ) -> SkipReason? {
    if CleanupExclusions.overlaps(url, paths: environment.excludedPaths) { return .excluded }
    guard (try? safety.validate(url)) != nil else { return .protected }

    if rule.checksOwnerApp, let owner = owningApp(of: url, running: running) {
      return .appRunning(owner)
    }
    if rule.minimumAge > 0,
      let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate,
      environment.now().timeIntervalSince(modified) < rule.minimumAge
    {
      return .recentlyModified
    }
    return nil
  }

  /// 条目名为反向域名时，匹配正在运行的应用（名称相同，或是其子标识）
  static func owningApp(of url: URL, running: Set<String>) -> String? {
    let name = url.lastPathComponent
    guard name.split(separator: ".").count >= 3 else { return nil }
    return running.first { name == $0 || name.hasPrefix($0 + ".") }
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
    try checkCancellation()
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    let values = try url.resourceValues(forKeys: Set(keys))
    guard values.isSymbolicLink != true else { return 0 }
    if values.isRegularFile == true {
      return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
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
    while let file = enumerator.nextObject() as? URL {
      try checkCancellation()
      let fileValues = try file.resourceValues(forKeys: Set(keys))
      guard fileValues.isRegularFile == true else { continue }
      total += UInt64(fileValues.totalFileAllocatedSize ?? fileValues.fileAllocatedSize ?? 0)
    }
    if let traversalError { throw traversalError }
    return total
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
    onProgress: (@Sendable (CleanProgress) async -> Void)? = nil
  ) async -> CleanReport {
    let safety = SafetyGuard(home: environment.home)
    var report = CleanReport()
    let selectedScans = scans.filter { selected.contains($0.id) && $0.isCleanable }
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
      if scan.rule.blockingApps.contains(where: { running.contains($0.bundleID) }) {
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
        progress: progress, onProgress: onProgress,
        report: &report, completedSteps: &completedSteps)
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
        for item in scan.items {
          let remaining: UInt64
          do { remaining = try scanAllocatedSize(of: item.url) } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
          { remaining = 0 } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
          { remaining = 0 }
          log?.record(item: item, rule: scan.rule, action: "tool", detail: scan.rule.requiredTool)
          guard remaining < item.size else { continue }
          report.freedBytes += item.size - remaining
          report.removedCount += 1
        }
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
    progress: RuleProgress, onProgress: (@Sendable (CleanProgress) async -> Void)?,
    report: inout CleanReport, completedSteps: inout Int
  ) async -> Bool {
    var running = running
    for item in scan.items {
      // 每个目录候选操作前刷新；不是逐个缓存文件刷新，避免大目录清理期间沿用旧快照。
      running = await refreshRunningApps?() ?? environment.runningBundleIdentifiers()
      if Task.isCancelled {
        report.wasCancelled = true
        return true
      }
      let blockingApp = scan.rule.blockingApps.first { running.contains($0.bundleID) }
      if let reason = blockingApp.map({ SkipReason.appRunning($0.name) })
        ?? skipReason(
          for: item.url, rule: scan.rule, running: running,
          environment: environment, safety: safety)
      {
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
          try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
          report.trashedBytes += item.size
        } else {
          try FileManager.default.removeItem(at: item.url)
          report.freedBytes += item.size
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
