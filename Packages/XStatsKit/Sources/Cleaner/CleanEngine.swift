import Foundation
import Localization

public enum CleanEngine {
    // MARK: 扫描

    /// 并发扫描所有规则，只读，不修改任何文件
    public static func scan(_ rules: [CleanRule], environment: CleanEnvironment) async -> [RuleScan] {
        let safety = SafetyGuard(home: environment.home)
        return await withTaskGroup(of: (Int, RuleScan).self) { group in
            for (index, rule) in rules.enumerated() {
                group.addTask { (index, await scanRule(rule, environment: environment, safety: safety)) }
            }
            var results = [(Int, RuleScan)]()
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func scanRule(_ rule: CleanRule, environment: CleanEnvironment, safety: SafetyGuard) async -> RuleScan {
        let running = environment.runningBundleIdentifiers()
        if let app = rule.blockingApps.first(where: { running.contains($0.bundleID) }) {
            return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .appRunning(app.name))
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
            candidates = try rule.locate(environment)
        } catch {
            return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .needsFullDiskAccess)
        }
        if !candidates.isEmpty, let tool = rule.requiredTool, !environment.isToolAvailable(tool) {
            return RuleScan(rule: rule, items: [], skippedCount: 0, blocked: .toolUnavailable(tool))
        }

        var items: [CleanItem] = []
        var skipped = 0
        for url in candidates {
            if Task.isCancelled { break }
            // 工具托管的缓存由工具自身处理锁与内部目录；这里的路径只用于只读计量，不能套用
            // “应用数据保护词”过滤，否则名为 xstats 等普通包会被误报为正在使用。
            if !rule.usesToolCleaner,
               skipReason(for: url, rule: rule, running: running, environment: environment, safety: safety) != nil {
                skipped += 1
                continue
            }
            let size = allocatedSize(of: url)
            if size > 0 { items.append(CleanItem(url: url, size: size)) }
        }
        items.sort { $0.size > $1.size }
        return RuleScan(rule: rule, items: items, skippedCount: skipped, blocked: nil)
    }

    static func skipReason(for url: URL, rule: CleanRule, running: Set<String>,
                           environment: CleanEnvironment, safety: SafetyGuard) -> SkipReason? {
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
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { return 0 }
        if values.isRegularFile == true {
            return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        while let file = enumerator.nextObject() as? URL {
            guard let fileValues = try? file.resourceValues(forKeys: Set(keys)),
                  fileValues.isRegularFile == true else { continue }
            total += UInt64(fileValues.totalFileAllocatedSize ?? fileValues.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: 清理

    /// 清理选中规则的扫描结果。执行前逐项重新校验：扫描到执行之间应用可能已经启动
    public static func clean(_ scans: [RuleScan], selected: Set<String>, preferTrash: Bool,
                             environment: CleanEnvironment, log: CleanLog? = CleanLog(),
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
            let running = environment.runningBundleIdentifiers()
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
                    let toolReport = try await cleanWithTool(environment)
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
                            let remaining = allocatedSize(of: item.url)
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
                if Task.isCancelled { report.wasCancelled = true; return report }
                if let reason = skipReason(for: item.url, rule: scan.rule, running: running,
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
