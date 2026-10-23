// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

/// 开发者清理清单：每条规则在这里定义范围来源、保护条件和本次原生操作。
/// 仅参考上游的功能范围，Swift 实现独立编写。候选生成后不回退到另一套路径或命令。
enum DeveloperCleanupCatalog {
  static let rules: [CleanRule] = [
    xcodeDerivedData, simulatorCaches, npmCache, yarnCache, pnpmCache, bunCache,
    goCache, rustCache, uvCache, pipCache, homebrewCache, vscodeCache, cursorCache, xcodeArchives,
  ]

  static let xcodeDerivedData = CleanRule(
    id: "developer.derivedData", category: .developer, title: tr("Xcode 编译缓存"),
    detail: tr("DerivedData，下次编译时自动重建"), symbol: "hammer",
    blockingApps: [("com.apple.dt.Xcode", "Xcode")]
  ) { env in
    try RuleCatalog.childrenIfExists(of: env.home + "/Library/Developer/Xcode/DerivedData")
  }

  static let simulatorCaches = CleanRule(
    id: "developer.simulatorCaches", category: .developer, title: tr("模拟器缓存"),
    detail: tr("CoreSimulator 的动态库与运行时缓存"), symbol: "iphone",
    blockingApps: [("com.apple.iphonesimulator", tr("模拟器"))]
  ) { env in
    try RuleCatalog.childrenIfExists(of: env.home + "/Library/Developer/CoreSimulator/Caches")
  }

  static let xcodeArchives = CleanRule(
    id: "developer.archives", category: .developer, title: tr("Xcode 归档"),
    detail: tr("打包生成的 .xcarchive，删除后无法重新符号化旧版本崩溃日志"), symbol: "archivebox.fill",
    selectedByDefault: false, policy: .trash, minimumAge: 0
  ) { env in
    try RuleCatalog.childrenIfExists(of: env.home + "/Library/Developer/Xcode/Archives")
  }

  static let npmCache = CleanRule(
    id: "developer.npm", category: .developer, title: tr("npm 缓存"),
    detail: tr("npm 下载缓存，由 npm 自行清理"), symbol: "tool-npm",
    selectedByDefault: false, minimumAge: 0, requiredTool: "npm",
    prepareTool: { env in
      let cache = try await ToolCachePlan.queryPath(
        "npm", ["config", "get", "cache"], environment: env)
      return ToolCachePlan(
        roots: [cache.appendingPathComponent("_cacache")], tool: "npm",
        arguments: ["cache", "clean", "--force", "--cache", cache.path])
    })

  static let yarnCache = CleanRule(
    id: "developer.yarn", category: .developer, title: tr("Yarn 缓存"),
    detail: tr("Yarn 全局与离线镜像缓存，由 Yarn 自行清理"), symbol: "tool-yarn",
    selectedByDefault: false, minimumAge: 0, requiredTool: "yarn",
    prepareTool: { env in
      let result = try await env.inspectTool("yarn", ["--version"])
      guard result.status == 0, result.output.utf8.count <= 128,
        let major = Int(
          result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").first
            ?? ""),
        major >= 1
      else { throw ToolCachePlanError.unknownScope }
      if major >= 2 {
        // Berry 还会调用插件的全局清理钩子，已知缓存位置不等于完整删除边界。
        guard env.excludedPaths.isEmpty else { throw ToolCachePlanError.unknownScope }
        let cache = try await ToolCachePlan.queryPath(
          "yarn", ["config", "get", "cacheFolder", "--json"], environment: env, jsonOutput: true)
        let global = try await ToolCachePlan.queryPath(
          "yarn", ["config", "get", "globalFolder", "--json"], environment: env, jsonOutput: true)
        return ToolCachePlan(
          roots: [cache, global.appendingPathComponent("cache")], tool: "yarn",
          arguments: ["cache", "clean", "--all"],
          environmentOverrides: [
            "YARN_CACHE_FOLDER": cache.path, "YARN_GLOBAL_FOLDER": global.path,
          ],
          hasBoundedScope: false)
      }
      let cache = try await ToolCachePlan.queryPath("yarn", ["cache", "dir"], environment: env)
      let configured = try await ToolCachePlan.pinnedDirectory(
        "yarn", query: ["cache", "dir"], flag: "--cache-folder",
        reported: cache, environment: env)
      // Classic cache dir 返回 vN，但无包名的 cache clean 删除整个 _cacheRootFolder。
      return ToolCachePlan(
        roots: [configured], tool: "yarn",
        arguments: ["cache", "clean", "--cache-folder", configured.path])
    })

  static let pnpmCache = CleanRule(
    id: "developer.pnpm", category: .developer, title: tr("pnpm 缓存"),
    detail: tr("pnpm 内容寻址存储，仅清理未被引用的包"), symbol: "tool-pnpm",
    selectedByDefault: false, minimumAge: 0, requiredTool: "pnpm",
    prepareTool: { env in
      let cache = try await ToolCachePlan.queryPath("pnpm", ["store", "path"], environment: env)
      let configured = try await ToolCachePlan.pinnedDirectory(
        "pnpm", query: ["store", "path"], flag: "--store-dir",
        reported: cache, environment: env)
      return ToolCachePlan(
        roots: [cache], tool: "pnpm", arguments: ["store", "prune", "--store-dir", configured.path])
    })

  static let bunCache = CleanRule(
    id: "developer.bun", category: .developer, title: tr("Bun 缓存"),
    detail: tr("Bun 下载的包缓存，由 Bun 自行清理"), symbol: "tool-bun",
    selectedByDefault: false, minimumAge: 0, requiredTool: "bun",
    prepareTool: { env in
      let cache = try await ToolCachePlan.queryPath("bun", ["pm", "cache"], environment: env)
      // pm cache 不可靠地接受 --cache-dir；独立工作目录由工具执行器负责。
      return ToolCachePlan(
        roots: [cache], tool: "bun", arguments: ["pm", "cache", "rm"],
        environmentOverrides: ["BUN_INSTALL_CACHE_DIR": cache.path])
    })

  static let goCache = CleanRule(
    id: "developer.go", category: .developer, title: tr("Go 缓存"),
    detail: tr("Go 编译与完整模块缓存，由 go clean 清理"), symbol: "tool-go",
    selectedByDefault: false, minimumAge: 0, requiredTool: "go",
    prepareTool: { env in
      let result = try await env.inspectTool("go", ["env", "-json", "GOCACHE", "GOMODCACHE"])
      guard result.status == 0, result.output.utf8.count <= 8192,
        let values = try? JSONDecoder().decode(
          [String: String].self, from: Data(result.output.utf8)),
        let modules = values["GOMODCACHE"], let build = values["GOCACHE"]
      else { throw ToolCachePlanError.unknownScope }
      let moduleCache = try ToolCachePlan.validatedPath(modules, home: env.home)
      let buildCache = build == "off" ? nil : try ToolCachePlan.validatedPath(build, home: env.home)
      return ToolCachePlan(
        roots: buildCache.map { [$0, moduleCache] } ?? [moduleCache], tool: "go",
        arguments: ["clean", "-cache", "-modcache"],
        environmentOverrides: [
          "GOCACHE": buildCache?.path ?? "off", "GOMODCACHE": moduleCache.path,
        ])
    })

  static let rustCache = CleanRule(
    id: "developer.rust", category: .developer, title: tr("Rust 缓存"),
    detail: tr("Cargo 注册表与 Git 依赖缓存，需要 cargo-cache"), symbol: "tool-rust",
    selectedByDefault: false, minimumAge: 0, requiredTool: "cargo-cache",
    prepareTool: { env in
      let roots = try rustStorageRoots(environment: env)
      let cargo = roots[0].deletingLastPathComponent()
      return ToolCachePlan(
        roots: roots,
        tool: "cargo-cache", arguments: ["-r", "all"],
        environmentOverrides: ["CARGO_HOME": cargo.path])
    })

  /// Cargo 存储由配置直接确定；即使 cargo-cache 缺失，通用规则也不能接管。
  static func rustStorageRoots(environment: CleanEnvironment) throws -> [URL] {
    let cargo = try ToolCachePlan.validatedPath(
      environment.toolEnvironment["CARGO_HOME"] ?? environment.home + "/.cargo",
      home: environment.home)
    return [cargo.appendingPathComponent("registry"), cargo.appendingPathComponent("git")]
  }

  static let uvCache = CleanRule(
    id: "developer.uv", category: .developer, title: tr("uv 缓存"),
    detail: tr("uv 下载的 Python 包与构建缓存，由 uv 自行清理"), symbol: "tool-uv",
    selectedByDefault: false, minimumAge: 0, requiredTool: "uv",
    prepareTool: { env in
      let cache = try await ToolCachePlan.queryPath("uv", ["cache", "dir"], environment: env)
      return ToolCachePlan(
        roots: [cache], tool: "uv", arguments: ["cache", "clean", "--cache-dir", cache.path])
    })

  static let pipCache = CleanRule(
    id: "developer.pip", category: .developer, title: tr("pip 缓存"),
    detail: tr("pip3 下载与 wheel 缓存，不涉及虚拟环境或已安装的包"), symbol: "shippingbox",
    selectedByDefault: false, minimumAge: 0, requiredTool: "pip3",
    prepareTool: { env in
      let cache = try await ToolCachePlan.queryPath("pip3", ["cache", "dir"], environment: env)
      return ToolCachePlan(
        roots: [cache], tool: "pip3", arguments: ["cache", "purge", "--cache-dir", cache.path])
    })

  static let homebrewCache = CleanRule(
    id: "developer.homebrew", category: .developer, title: tr("Homebrew 清理"),
    detail: tr("由 Homebrew 清理旧版本与缓存，不自动移除依赖"), symbol: "shippingbox",
    selectedByDefault: false, minimumAge: 0, requiredTool: "brew",
    prepareTool: { env in
      guard env.excludedPaths.isEmpty else { throw ToolCachePlanError.unknownScope }
      let result = try await env.runTool("brew", ["cleanup", "--prune=30", "--dry-run"])
      guard result.status == 0 else {
        throw ToolExecutionError.failed(
          tool: "brew", status: result.status, output: String(result.output.prefix(2_000)))
      }
      let preview = try HomebrewCleanup.parsePreview(result.output)
      return ToolCachePlan(
        roots: preview.items.map(\.url), tool: "brew", arguments: ["cleanup", "--prune=30"],
        hasBoundedScope: false, preview: preview, parseReport: HomebrewCleanup.report)
    })

  static let vscodeCache = ApplicationCacheCatalog.cache(
    id: "developer.vscode", name: "VS Code", directories: ["Code", "Code - Insiders"],
    names: ["Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs"],
    bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
    applicationNames: [
      "Visual Studio Code", "Visual Studio Code - Insiders", "Visual Studio Code Insiders",
    ], category: .developer)
  static let cursorCache = ApplicationCacheCatalog.cache(
    id: "developer.cursor", name: "Cursor", directories: ["Cursor"],
    names: ["Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs"],
    bundleIDs: ["com.todesktop.230313mzl4w4u92"], category: .developer)
}
