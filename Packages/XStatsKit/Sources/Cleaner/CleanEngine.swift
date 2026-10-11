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
                    let index = next, rule = rules[next]
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
                return RuleScan(rule: scan.rule, items: items, skippedCount: scan.skippedCount + scan.items.count - items.count,
                                blocked: scan.blocked, skippedReasons: scan.skippedReasons, unreadableCount: scan.unreadableCount)
            }
        }
    }

    static func scanRule(_ rule: CleanRule, environment: CleanEnvironment, safety: SafetyGuard) async -> RuleScan {
        let running = environment.runningBundleIdentifiers()
        if let app = rule.blockingApps.first(where: { running.contains($0.bundleID) }) {
            return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .appRunning(app.name))
        }
        var toolCachePlan: ToolCachePlan?
        if rule.usesToolCleaner {
            if let tool = rule.requiredTool, !environment.isToolAvailable(tool) {
                return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .toolUnavailable(tool))
            }
            do {
                toolCachePlan = try await ToolCachePlan.resolve(for: rule, environment: environment)
                if !environment.excludedPaths.isEmpty {
                    // Homebrew 等全局操作无法锁定全部删除路径；有保留要求时不能凭默认目录放行。
                    guard let plan = toolCachePlan else { throw ToolCachePlanError.unknownScope }
                    if plan.roots.contains(where: { CleanupExclusions.overlaps($0, paths: environment.excludedPaths) }) {
                        return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .excluded)
                    }
                }
            } catch {
                return RuleScan(rule: rule, items: [], skippedCount: 0,
                                blocked: .previewFailed(String(error.localizedDescription.prefix(1024))))
            }
        }
        if let previewWithTool = rule.previewWithTool {
            if let tool = rule.requiredTool, !environment.isToolAvailable(tool) {
                return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .toolUnavailable(tool))
            }
            do {
                let preview = try await previewWithTool(environment)
                return RuleScan(rule: rule, items: preview.items, skippedCount: 0, blocked: nil, toolPreview: preview)
            } catch {
                return RuleScan(rule: rule, items: [], skippedCount: 0,
                                blocked: .previewFailed(error.localizedDescription))
            }
        }

        let candidates: [URL]
        do {
            candidates = try toolCachePlan?.roots.filter { FileManager.default.fileExists(atPath: $0.path) } ?? rule.locate(environment)
        } catch {
            let failure = error as NSError
            let permission = error is CleanerAccessError || (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError)
                || (failure.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(failure.code))
            return RuleScan(rule: rule, items: [], skippedCount: 0,
                            blocked: permission ? .needsFullDiskAccess : .previewFailed(String(error.localizedDescription.prefix(1024))))
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
               let reason = skipReason(for: url, rule: rule, running: running, environment: environment, safety: safety) {
                skipped += 1
                reasons[reason, default: 0] += 1
                continue
            }
            do {
                let size = try scanAllocatedSize(of: url)
                if size > 0 { items.append(CleanItem(url: url, size: size)) }
            } catch is CancellationError { break }
            catch { unreadable += 1 }
        }
        items.sort { $0.size > $1.size }
        return RuleScan(rule: rule, items: items, skippedCount: skipped, blocked: nil,
                        skippedReasons: reasons, unreadableCount: unreadable, toolCachePlan: toolCachePlan)
    }

    static func skipReason(for url: URL, rule: CleanRule, running: Set<String>,
                           environment: CleanEnvironment, safety: SafetyGuard) -> SkipReason? {
        if CleanupExclusions.overlaps(url, paths: environment.excludedPaths) { return .excluded }
        guard (try? safety.validate(url)) != nil else { return .protected }

        if rule.checksOwnerApp, let owner = owningApp(of: url, running: running) {
            return .appRunning(owner)
        }
        if rule.minimumAge > 0,
           let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           environment.now().timeIntervalSince(modified) < rule.minimumAge {
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

    /// 实际占用的磁盘空间；不跟随符号链接
    public static func allocatedSize(of url: URL) -> UInt64 {
        // 保持同步调用方的完整计量语义；可取消操作使用 throwing 入口，不能把部分结果当完整大小。
        (try? scanAllocatedSize(of: url, checkCancellation: {})) ?? 0
    }

    /// 完整体积计量，遍历期间响应取消；取消时抛错，不返回部分大小。
    public static func scanAllocatedSize(of url: URL,
                                  checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> UInt64 {
        try checkCancellation()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let values = try url.resourceValues(forKeys: Set(keys))
        guard values.isSymbolicLink != true else { return 0 }
        if values.isRegularFile == true {
            return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var traversalError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, error in traversalError = error; return false }) else {
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

    /// 清理选中规则的扫描结果。执行前逐项重新校验：扫描到执行之间应用可能已经启动
    public static func clean(_ scans: [RuleScan], selected: Set<String>, preferTrash: Bool,
                             environment: CleanEnvironment, log: CleanLog? = CleanLog(),
                             refreshRunningApps: (@Sendable () async -> Set<String>)? = nil,
                             onProgress: (@Sendable (CleanProgress) async -> Void)? = nil) async -> CleanReport {
        let safety = SafetyGuard(home: environment.home)
        var report = CleanReport()
        let selectedScans = scans.filter { selected.contains($0.id) && $0.isCleanable }
        let totalSteps = selectedScans.reduce(0) { $0 + ($1.rule.usesToolCleaner ? 1 : $1.items.count) }
        let progressInterval = max(1, (totalSteps + 99) / 100)
        var completedSteps = 0

        for (ruleIndex, scan) in selectedScans.enumerated() {
            if Task.isCancelled { report.wasCancelled = true; return report }
            let completedBeforeRule = completedSteps
            let currentRuleTotal = scan.rule.usesToolCleaner ? 1 : scan.items.count
            let currentRuleStartedAt = Date()
            let currentProgress = {
                CleanProgress(completed: completedSteps, total: totalSteps, currentRule: scan.rule.title,
                              ruleNumber: ruleIndex + 1, ruleCount: selectedScans.count,
                              currentRuleCompleted: completedSteps - completedBeforeRule,
                              currentRuleTotal: currentRuleTotal, currentRuleStartedAt: currentRuleStartedAt,
                              toolScannedBytes: scan.rule.usesToolCleaner ? scan.totalSize : nil)
            }
            await onProgress?(currentProgress())
            var running = await refreshRunningApps?() ?? environment.runningBundleIdentifiers()
            if scan.rule.usesToolCleaner, !environment.excludedPaths.isEmpty, scan.toolCachePlan == nil {
                report.failures.append(ToolCachePlanError.unknownScope.localizedDescription)
                completedSteps += currentRuleTotal
                await onProgress?(currentProgress())
                continue
            }
            if scan.rule.usesToolCleaner, ((scan.toolCachePlan?.roots ?? []) + scan.items.map(\.url)).contains(where: {
                CleanupExclusions.overlaps($0, paths: environment.excludedPaths)
            }) {
                report.skippedCount += scan.items.count
                completedSteps += currentRuleTotal
                await onProgress?(currentProgress())
                continue
            }
            if scan.rule.blockingApps.contains(where: { running.contains($0.bundleID) }) {
                report.skippedCount += scan.items.count
                completedSteps += currentRuleTotal
                await onProgress?(currentProgress())
                continue
            }
            if let cleanWithTool = scan.rule.cleanWithTool {
                if let tool = scan.rule.requiredTool, !environment.isToolAvailable(tool) {
                    report.failures.append(tr("\(scan.rule.title)：未找到 \(tool)，无法安全清理"))
                    completedSteps += 1
                    await onProgress?(currentProgress())
                    continue
                }
                do {
                    let toolReport: CleanReport?
                    if let plan = scan.toolCachePlan {
                        _ = try await plan.execute(in: environment)
                        toolReport = nil
                    } else {
                        toolReport = try await cleanWithTool(environment)
                    }
                    if let toolReport {
                        report.freedBytes += toolReport.freedBytes
                        report.removedCount += toolReport.removedCount
                        report.skippedCount += toolReport.skippedCount
                        report.failures += toolReport.failures
                        report.trashedBytes += toolReport.trashedBytes
                        report.wasCancelled = toolReport.wasCancelled
                        report.hasUncertainFreedBytes = report.hasUncertainFreedBytes || toolReport.hasUncertainFreedBytes
                        log?.recordTool(rule: scan.rule, report: toolReport)
                        if report.wasCancelled { return report }
                    } else {
                        for item in scan.items {
                            let remaining: UInt64
                            do { remaining = try scanAllocatedSize(of: item.url) }
                            catch let error as CocoaError where error.code == .fileReadNoSuchFile { remaining = 0 }
                            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { remaining = 0 }
                            log?.record(item: item, rule: scan.rule, action: "tool", detail: scan.rule.requiredTool)
                            guard remaining < item.size else { continue }
                            report.freedBytes += item.size - remaining
                            report.removedCount += 1
                        }
                    }
                } catch {
                    // 外部命令可能已删除部分内容，失败或取消后都无法从扫描结果确认实际释放量。
                    report.hasUncertainFreedBytes = true
                    log?.recordToolInterruption(rule: scan.rule, error: error,
                                                cancelled: error is CancellationError || Task.isCancelled)
                    if error is CancellationError || Task.isCancelled {
                        report.wasCancelled = true
                        return report
                    }
                    report.failures.append(tr("\(scan.rule.title)：\(error.localizedDescription)"))
                }
                completedSteps += 1
                await onProgress?(currentProgress())
                continue
            }
            // 工具预览中的路径不受文件规则白名单约束，因此绝不能回退到手动删除。
            guard scan.rule.previewWithTool == nil else {
                completedSteps += scan.items.count
                await onProgress?(currentProgress())
                continue
            }
            let useTrash = !scan.rule.deletesPermanently(preferTrash: preferTrash)

            for item in scan.items {
                // 每个目录候选操作前刷新；不是逐个缓存文件刷新，避免大目录清理期间沿用旧快照。
                running = await refreshRunningApps?() ?? environment.runningBundleIdentifiers()
                if Task.isCancelled { report.wasCancelled = true; return report }
                let blockingApp = scan.rule.blockingApps.first { running.contains($0.bundleID) }
                if let reason = blockingApp.map({ SkipReason.appRunning($0.name) }) ?? skipReason(for: item.url, rule: scan.rule, running: running,
                                           environment: environment, safety: safety) {
                    report.skippedCount += 1
                    log?.record(item: item, rule: scan.rule, action: "skip", detail: reason.title)
                    completedSteps += 1
                    if completedSteps % progressInterval == 0 || completedSteps - completedBeforeRule == currentRuleTotal {
                        await onProgress?(currentProgress())
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
                if completedSteps % progressInterval == 0 || completedSteps - completedBeforeRule == currentRuleTotal {
                    await onProgress?(currentProgress())
                }
            }
        }
        return report
    }
}

/// 清理操作日志：~/Library/Logs/XStats/cleanup.log，每行一条 JSON
public struct CleanLog: Sendable {
    public let url: URL

    public init(url: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/XStats/cleanup.log")) {
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
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
