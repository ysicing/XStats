// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

enum ToolCachePlanError: Error, LocalizedError {
    case unknownScope

    var errorDescription: String? { tr("无法确认工具的清理范围，已停止清理") }
}

/// 原生工具的缓存位置与执行约束。扫描与执行复用同一计划，配置改变不会扩大清理范围。
public struct ToolCachePlan: Sendable {
    public let roots: [URL]
    let tool: String
    let arguments: [String]
    let environmentOverrides: [String: String]

    func execute(in environment: CleanEnvironment) async throws -> ToolRunResult {
        if environmentOverrides.isEmpty { return try await environment.runTool(tool, arguments) }
        return try await environment.runToolWithEnvironment(tool, arguments, environmentOverrides)
    }

    /// 只读查询按需运行，不增加后台轮询；异常、相对路径或无法约束的版本不回退到默认目录。
    static func resolve(for rule: CleanRule, environment: CleanEnvironment) async throws -> ToolCachePlan? {
        let tool = rule.requiredTool ?? ""
        let roots: [URL]
        let arguments: [String]
        var overrides: [String: String] = [:]
        switch rule.id {
        case "developer.npm":
            let cache = try await queryPath(tool, ["config", "get", "cache"], environment: environment)
            roots = [cache.appendingPathComponent("_cacache")]
            arguments = ["cache", "clean", "--force", "--cache", cache.path]
        case "developer.uv":
            let cache = try await queryPath(tool, ["cache", "dir"], environment: environment)
            roots = [cache]
            arguments = ["cache", "clean", "--cache-dir", cache.path]
        case "developer.bun":
            let cache = try await queryPath(tool, ["pm", "cache"], environment: environment)
            roots = [cache]
            // pm cache 不可靠地接受 --cache-dir，使用 Bun 明确支持的缓存环境变量。
            overrides = ["BUN_INSTALL_CACHE_DIR": cache.path]
            arguments = ["pm", "cache", "rm"]
        case "developer.pnpm":
            let cache = try await queryPath(tool, ["store", "path"], environment: environment)
            let configured = try await pinnedDirectory(tool, query: ["store", "path"], flag: "--store-dir",
                                                       reported: cache, environment: environment)
            roots = [cache]
            arguments = ["store", "prune", "--store-dir", configured.path]
        case "developer.yarn":
            let version = try await environment.inspectTool(tool, ["--version"])
            guard version.status == 0, version.output.utf8.count <= 128,
                  let major = Int(version.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").first ?? ""),
                  major >= 1 else { throw ToolCachePlanError.unknownScope }
            // Berry 的 --all 涉及项目缓存和全局镜像，不能用 Classic 的目录选项约束。
            if major >= 2 { return nil }
            let cache = try await queryPath(tool, ["cache", "dir"], environment: environment)
            let configured = try await pinnedDirectory(tool, query: ["cache", "dir"], flag: "--cache-folder",
                                                       reported: cache, environment: environment)
            // Classic cache dir 返回 vN 子目录，但无包名的 cache clean 删除 _cacheRootFolder。
            // 必须预览并保护配置父目录，否则兄弟目录会在未被预览的情况下被删除。
            roots = [configured]
            arguments = ["cache", "clean", "--cache-folder", configured.path]
        case "developer.go":
            let result = try await environment.inspectTool(tool, ["env", "-json", "GOCACHE", "GOMODCACHE"])
            guard result.status == 0, result.output.utf8.count <= 8192,
                  let values = try? JSONDecoder().decode([String: String].self, from: Data(result.output.utf8)),
                  let modules = values["GOMODCACHE"], let build = values["GOCACHE"] else { throw ToolCachePlanError.unknownScope }
            let moduleCache = try validatedPath(modules, home: environment.home)
            let buildCache = build == "off" ? nil : try validatedPath(build, home: environment.home)
            roots = buildCache.map { [$0, moduleCache] } ?? [moduleCache]
            overrides = ["GOCACHE": buildCache?.path ?? "off", "GOMODCACHE": moduleCache.path]
            arguments = ["clean", "-cache", "-modcache"]
        case "developer.rust":
            // cargo-cache 使用 CARGO_HOME；固定该变量，不能沿用默认目录计量却清理另一个 home。
            let cargo = try validatedPath(environment.toolEnvironment["CARGO_HOME"] ?? environment.home + "/.cargo",
                                          home: environment.home)
            roots = [cargo.appendingPathComponent("registry"), cargo.appendingPathComponent("git")]
            overrides = ["CARGO_HOME": cargo.path]
            arguments = ["-r", "all"]
        default:
            return nil
        }
        // 自定义配置可能让一个缓存根嵌套在另一个根内，只计量父候选一次。
        var distinctRoots: [URL] = []
        for root in Set(roots).sorted(by: { $0.path.count < $1.path.count }) {
            if !distinctRoots.contains(where: { root.path == $0.path || root.path.hasPrefix($0.path + "/") }) {
                distinctRoots.append(root)
            }
        }
        return ToolCachePlan(roots: distinctRoots, tool: tool, arguments: arguments, environmentOverrides: overrides)
    }

    private static func queryPath(_ tool: String, _ arguments: [String], environment: CleanEnvironment) async throws -> URL {
        try Task.checkCancellation()
        let result = try await environment.inspectTool(tool, arguments)
        guard result.status == 0 else { throw ToolCachePlanError.unknownScope }
        return try validatedPath(result.output, home: environment.home)
    }

    private static func validatedPath(_ output: String, home: String) throws -> URL {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ToolCachePlanError.unknownScope }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let userHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        // 配置输出不能把用户根目录或其祖先当成缓存根，防止错误配置扩大整个工具操作。
        guard url.path != "/", url.path != userHome, !userHome.hasPrefix(url.path + "/") else { throw ToolCachePlanError.unknownScope }
        return url
    }

    /// pnpm / Yarn 会在配置目录下追加版本子目录；不能把查询结果再当配置值，形成 vN/vN。
    private static func pinnedDirectory(_ tool: String, query: [String], flag: String,
                                        reported: URL, environment: CleanEnvironment) async throws -> URL {
        for candidate in [reported, reported.deletingLastPathComponent()] {
            let root = try validatedPath(candidate.path, home: environment.home)
            let pinned = try await queryPath(tool, query + [flag, root.path], environment: environment)
            if pinned == reported { return root }
        }
        throw ToolCachePlanError.unknownScope
    }
}
