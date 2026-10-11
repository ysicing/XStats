// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

enum ToolCachePlanError: Error, LocalizedError {
    case unknownScope

    var errorDescription: String? { tr("无法确认工具的清理范围，已停止清理") }
}

/// 原生工具本次清理计划：有界操作固定缓存位置，全局操作明确标记其保护限制。
public struct ToolCachePlan: Sendable {
    public let roots: [URL]
    let tool: String
    let arguments: [String]
    let environmentOverrides: [String: String]

    /// 全局操作（如 Homebrew）不能证明完整路径边界；有保留项时必须停止。
    let hasBoundedScope: Bool
    let preview: ToolCleanupPreview?
    private let parseReport: (@Sendable (ToolRunResult) throws -> CleanReport)?

    init(roots: [URL], tool: String, arguments: [String], environmentOverrides: [String: String] = [:],
         hasBoundedScope: Bool = true, preview: ToolCleanupPreview? = nil,
         parseReport: (@Sendable (ToolRunResult) throws -> CleanReport)? = nil) {
        // 有界缓存的根可能嵌套，计量一次即可；全局原生预览按工具提供的候选呈现。
        var distinctRoots: [URL] = []
        for root in (preview == nil ? Set(roots).sorted(by: { $0.path.count < $1.path.count }) : []) {
            if !distinctRoots.contains(where: { root.path == $0.path || root.path.hasPrefix($0.path + "/") }) {
                distinctRoots.append(root)
            }
        }
        self.roots = preview == nil ? distinctRoots : roots
        self.tool = tool; self.arguments = arguments; self.environmentOverrides = environmentOverrides
        self.hasBoundedScope = hasBoundedScope; self.preview = preview; self.parseReport = parseReport
    }

    func execute(in environment: CleanEnvironment) async throws -> CleanReport? {
        let result: ToolRunResult
        if environmentOverrides.isEmpty { result = try await environment.runTool(tool, arguments) }
        else { result = try await environment.runToolWithEnvironment(tool, arguments, environmentOverrides) }
        guard result.status == 0 else {
            throw ToolExecutionError.failed(tool: tool, status: result.status, output: String(result.output.prefix(2_000)))
        }
        return try parseReport?(result)
    }

    static func queryPath(_ tool: String, _ arguments: [String], environment: CleanEnvironment, jsonOutput: Bool = false) async throws -> URL {
        try Task.checkCancellation()
        let result = try await environment.inspectTool(tool, arguments)
        guard result.status == 0 else { throw ToolCachePlanError.unknownScope }
        if jsonOutput {
            guard result.output.utf8.count <= 8192,
                  let path = try? JSONDecoder().decode(String.self, from: Data(result.output.utf8)) else { throw ToolCachePlanError.unknownScope }
            return try validatedPath(path, home: environment.home)
        }
        return try validatedPath(result.output, home: environment.home)
    }

    static func validatedPath(_ output: String, home: String) throws -> URL {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // 保持显式闭包：当前工具链的 Release 构建曾将实例方法引用误判为命中控制字符。
        // 正常路径与非法路径都需要在优化构建中验证，不能仅依赖 Debug 测试。
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ToolCachePlanError.unknownScope }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let userHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        // 配置输出不能把用户根目录或其祖先当成缓存根，防止错误配置扩大整个工具操作。
        guard url.path != "/", url.path != userHome, !userHome.hasPrefix(url.path + "/") else { throw ToolCachePlanError.unknownScope }
        return url
    }

    /// pnpm / Yarn 会在配置目录下追加版本子目录；不能把查询结果再当配置值，形成 vN/vN。
    static func pinnedDirectory(_ tool: String, query: [String], flag: String,
                                        reported: URL, environment: CleanEnvironment) async throws -> URL {
        for candidate in [reported, reported.deletingLastPathComponent()] {
            let root = try validatedPath(candidate.path, home: environment.home)
            let pinned = try await queryPath(tool, query + [flag, root.path], environment: environment)
            if pinned == reported { return root }
        }
        throw ToolCachePlanError.unknownScope
    }
}
