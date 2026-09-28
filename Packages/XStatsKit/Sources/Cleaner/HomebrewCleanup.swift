// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

/// 路径与空间估算来自 brew 自己的计划，实际删除始终交给 brew；不根据输出拼接删除命令。
enum HomebrewCleanup {
    enum PreviewError: Error, LocalizedError {
        case unsupportedOutput

        var errorDescription: String? { tr("无法识别 Homebrew 清理预览，请在终端检查命令输出") }
    }

    static func preview(_ environment: CleanEnvironment) async throws -> ToolCleanupPreview {
        let result = try await environment.runTool("brew", ["cleanup", "--prune=30", "--dry-run"])
        guard result.status == 0 else {
            throw ToolExecutionError.failed(tool: "brew", status: result.status, output: String(result.output.prefix(2_000)))
        }
        return try parsePreview(result.output)
    }

    static func clean(_ environment: CleanEnvironment) async throws -> CleanReport? {
        let result = try await environment.runTool("brew", ["cleanup", "--prune=30"])
        guard result.status == 0 else {
            throw ToolExecutionError.failed(tool: "brew", status: result.status, output: String(result.output.prefix(2_000)))
        }
        if let report = result.cleanupReport { return report }
        var report = CleanReport()
        for line in result.output.components(separatedBy: .newlines) {
            try recordExecutionLine(line, report: &report)
        }
        return report
    }

    static func recordExecutionLine(_ line: String, report: inout CleanReport) throws {
        if line.hasPrefix("Removing: ") {
            report.removedCount += 1
        } else if line.hasPrefix("Pruning ") {
            // 格式为 "Pruning 57 files from: <path>..."，数量是 brew 实际删除的文件数。
            let count = line.dropFirst("Pruning ".count).prefix { $0 != " " }
            report.removedCount += Int(count) ?? 1
        }
        if let bytes = try summarySize(line, prefix: "==> This operation has freed approximately ") {
            report.freedBytes = bytes
        }
    }

    static func parsePreview(_ output: String) throws -> ToolCleanupPreview {
        var items: [CleanItem] = []
        var details: [String] = []
        var seen = Set<String>()
        var total: UInt64?
        var hasPrunedDirectory = false
        for line in output.components(separatedBy: .newlines) {
            if let bytes = try summarySize(line, prefix: "==> This operation would free approximately ") {
                total = bytes
                continue
            }
            let path: String
            let size: UInt64
            if line.hasPrefix("Would remove: ") {
                let entry = String(line.dropFirst("Would remove: ".count))
                guard entry.hasSuffix(")"), let separator = entry.range(of: " (", options: .backwards) else {
                    throw PreviewError.unsupportedOutput
                }
                path = String(entry[..<separator.lowerBound])
                let detail = entry[separator.upperBound...].dropLast()
                guard let sizeText = detail.components(separatedBy: ", ").last,
                      let bytes = parseSize(sizeText) else { throw PreviewError.unsupportedOutput }
                size = bytes
            } else if line.hasPrefix("Would prune "), let separator = line.range(of: " from: ") {
                path = String(line[separator.upperBound...])
                size = 0 // 只列出容器；实际待清理子集的大小由总计提供，不能用整个目录大小代替。
                hasPrunedDirectory = true
            } else if line.hasPrefix("Would remove (broken link): ") {
                path = String(line.dropFirst("Would remove (broken link): ".count))
                size = 0
            } else if line.hasPrefix("Would remove (empty directory): ") {
                path = String(line.dropFirst("Would remove (empty directory): ".count))
                size = 0
            } else {
                guard !line.hasPrefix("Would ") else { throw PreviewError.unsupportedOutput }
                continue // brew 的提示与跳过项不属于清理计划。
            }
            guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw PreviewError.unsupportedOutput
            }
            if seen.insert(path).inserted {
                items.append(CleanItem(url: URL(fileURLWithPath: path), size: size))
                details.append(line)
            }
        }
        guard !hasPrunedDirectory || total != nil, !items.isEmpty || total == nil || total == 0 else {
            throw PreviewError.unsupportedOutput
        }
        var itemTotal: UInt64 = 0
        for item in items {
            let (sum, overflow) = itemTotal.addingReportingOverflow(item.size)
            guard !overflow else { throw PreviewError.unsupportedOutput }
            itemTotal = sum
        }
        return ToolCleanupPreview(items: items, totalSize: total ?? itemTotal, details: details.joined(separator: "\n"))
    }

    private static func summarySize(_ line: String, prefix: String) throws -> UInt64? {
        guard line.hasPrefix(prefix) else { return nil }
        let suffix = " of disk space."
        guard line.hasSuffix(suffix), let bytes = parseSize(String(line.dropFirst(prefix.count).dropLast(suffix.count))) else {
            throw PreviewError.unsupportedOutput
        }
        return bytes
    }

    /// Homebrew 的 Formatter.disk_usage_readable 使用十进制单位，与本机语言无关。
    private static func parseSize(_ text: String) -> UInt64? {
        guard let unitStart = text.firstIndex(where: \.isLetter),
              let amount = Double(text[..<unitStart]), amount >= 0 else { return nil }
        let multiplier: Double
        switch text[unitStart...] {
        case "B": multiplier = 1
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        case "TB": multiplier = 1_000_000_000_000
        default: return nil
        }
        let bytes = (amount * multiplier).rounded()
        guard bytes.isFinite, bytes < Double(UInt64.max) else { return nil }
        return UInt64(bytes)
    }
}
