// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CoreFoundation
import os

public struct HomebrewPackage: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable { case formula, cask }
    public enum InstallReason: Sendable { case requested, dependency, unknown }
    public var id: String { kind.rawValue + ":" + name }
    /// Formula 的 full_name / Cask 的 full_token，保留自定义 tap，不能只按短名称执行。
    public let name: String
    public let displayName: String
    public let kind: Kind
    public let installedVersions: [String]
    public let latestVersion: String?
    public let outdated: Bool
    public let pinned: Bool
    public let installationURLs: [URL]
    public let applicationURLs: [URL]
    public let installedAt: Date?
    public let summary: String?
    public let installReason: InstallReason
    public var version: String { installedVersions.joined(separator: ", ") }

    init(name: String, displayName: String, kind: Kind, installedVersions: [String], latestVersion: String?,
         outdated: Bool, pinned: Bool, installationURLs: [URL], applicationURLs: [URL],
         installedAt: Date? = nil, summary: String? = nil, installReason: InstallReason = .unknown) {
        self.name = name; self.displayName = displayName; self.kind = kind
        self.installedVersions = installedVersions; self.latestVersion = latestVersion
        self.outdated = outdated; self.pinned = pinned
        self.installationURLs = installationURLs; self.applicationURLs = applicationURLs
        self.installedAt = installedAt; self.summary = summary; self.installReason = installReason
    }
}

public enum HomebrewManagement {
    public enum Action: String, Sendable { case upgrade, uninstall }
    public enum InventoryError: Error { case invalidOutput, invalidPackage }

    public static var isAvailable: Bool {
        DeveloperToolRunner.executable(named: "brew", home: NSHomeDirectory()) != nil
    }

    /// 只读本地清单；不执行 brew update，不触发自动更新、清理或依赖移除。
    @concurrent
    public static func inventory(home: String = NSHomeDirectory()) async throws -> [HomebrewPackage] {
        // 清单只解析 stdout；brew 的警告写入 stderr，丢弃以免混入 JSON。
        let prefix = try await DeveloperToolRunner.run("brew", arguments: ["--prefix"], home: home,
                                                      includesStandardError: false).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.hasPrefix("/"), !prefix.contains("\n") else { throw InventoryError.invalidOutput }
        let result = try await DeveloperToolRunner.run("brew", arguments: ["info", "--json=v2", "--installed"],
                                                      home: home, outputLimit: 16_000_000, includesStandardError: false)
        try Task.checkCancellation()
        return try parse(result.output, prefix: URL(fileURLWithPath: prefix))
    }

    /// 用户主动刷新远端索引；随后重新读取清单，由 Homebrew 判定 outdated。
    public static func checkUpdates(home: String = NSHomeDirectory()) async throws {
        _ = try await DeveloperToolRunner.run("brew", arguments: ["update"], home: home, previewTimeout: 300)
    }

    public static func perform(_ action: Action, package: HomebrewPackage, home: String = NSHomeDirectory()) async throws {
        let arguments = try arguments(for: action, package: package)
        // 不使用 --force / --ignore-dependencies / --zap，保留 Homebrew 的依赖与数据保护。
        _ = try await DeveloperToolRunner.run("brew", arguments: arguments, home: home,
            environmentOverrides: ["HOMEBREW_NO_INSTALL_CLEANUP": "1"])
    }

    static func arguments(for action: Action, package: HomebrewPackage) throws -> [String] {
        guard validToken(package.name), !(action == .upgrade && package.pinned) else { throw InventoryError.invalidPackage }
        return [action.rawValue, package.kind == .formula ? "--formula" : "--cask", package.name]
    }

    /// 解析完整、限量的原生清单（仅 stdout）；验证操作所用的包标识，未知安装路径保持空值。
    /// 顶层结构非法时整体失败；单个异常 Formula（缺字段、标识不合法）和重复包跳过，汇总记一条日志。
    /// Cask 决定应用的卸载路由：任一 Cask 无法识别时整体失败，由调用方降级并提示来源未知，
    /// 不能让被跳过的 Cask 应用静默走普通卸载。
    public static func parse(_ output: String, prefix: URL, home: String = NSHomeDirectory()) throws -> [HomebrewPackage] {
        guard let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let formulae = object["formulae"] as? [Any], let casks = object["casks"] as? [Any],
              formulae.count + casks.count <= 10_000 else { throw InventoryError.invalidOutput }
        var packages: [HomebrewPackage] = []
        var skipped = 0
        for formula in formulae {
            try Task.checkCancellation()
            guard let formula = formula as? [String: Any], let package = formulaPackage(formula, prefix: prefix) else {
                skipped += 1; continue
            }
            packages.append(package)
        }
        for cask in casks {
            try Task.checkCancellation()
            guard let cask = cask as? [String: Any], let package = caskPackage(cask, home: home) else {
                logger.notice("Homebrew inventory contains an unrecognized cask")
                throw InventoryError.invalidOutput
            }
            packages.append(package)
        }
        var seen = Set<String>()
        let unique = packages.filter { seen.insert($0.id).inserted }
        skipped += packages.count - unique.count
        if skipped > 0 {
            logger.notice("Homebrew inventory skipped invalid packages count=\(skipped, privacy: .public) kept=\(unique.count, privacy: .public)")
        }
        return unique.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static let logger = Logger(subsystem: "work.12306.xstats.app", category: "homebrew")

    private static func formulaPackage(_ formula: [String: Any], prefix: URL) -> HomebrewPackage? {
        guard let name = formula["full_name"] as? String, validToken(name),
              let short = formula["name"] as? String, validToken(short), !short.contains("/"),
              let installed = formula["installed"] as? [[String: Any]] else { return nil }
        let versions = installed.compactMap { $0["version"] as? String }
        guard !versions.isEmpty, versions.allSatisfy({ validToken($0) && !$0.contains("/") }) else { return nil }
        let stable = (formula["versions"] as? [String: Any])?["stable"] as? String
        let revision = formula["revision"] as? Int ?? 0
        let latest = stable.map { revision > 0 ? "\($0)_\(revision)" : $0 }
        // 现代 brew 不再返回 installed_as_dependency；缺失标记不能当成依赖。
        let reasons = installed.map { receipt -> Bool? in
            guard let flag = receipt["installed_on_request"] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            return flag.boolValue
        }
        let reason: HomebrewPackage.InstallReason = reasons.contains(true) ? .requested
            : reasons.allSatisfy({ $0 == false }) ? .dependency : .unknown
        return HomebrewPackage(name: name, displayName: short, kind: .formula, installedVersions: versions,
            latestVersion: latest, outdated: formula["outdated"] as? Bool ?? false, pinned: formula["pinned"] as? Bool ?? false,
            installationURLs: versions.map { prefix.appendingPathComponent("Cellar/\(short)/\($0)") }, applicationURLs: [],
            installedAt: installed.compactMap { installationDate($0["time"]) }.max(),
            summary: packageSummary(formula["desc"]), installReason: reason)
    }

    private static func caskPackage(_ cask: [String: Any], home: String) -> HomebrewPackage? {
        guard let name = cask["full_token"] as? String, validToken(name),
              let installed = cask["installed"] as? String else { return nil }
        let applications = (cask["artifacts"] as? [[String: Any]] ?? []).compactMap { artifact -> URL? in
            guard let entries = artifact["app"] as? [Any] else { return nil }
            return applicationURL(entries, home: home, resolvedTarget: artifact["target"] as? String)
        }
        return HomebrewPackage(name: name, displayName: (cask["name"] as? [String])?.first ?? name, kind: .cask,
            installedVersions: [installed], latestVersion: cask["version"] as? String,
            outdated: cask["outdated"] as? Bool ?? false, pinned: cask["pinned"] as? Bool ?? false,
            installationURLs: applications, applicationURLs: applications,
            installedAt: installationDate(cask["installed_time"]), summary: packageSummary(cask["desc"]))
    }

    private static func installationDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0, seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func packageSummary(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let summary = String(text.prefix(2_048)).trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    /// 优先使用 brew v2 JSON 产物外层已解析的 target，保留自定义 appdir。
    /// 缺失时才解析 app 数组中的 target：绝对路径直接使用，`~` 展开，相对路径落在 /Applications；
    /// 两者均缺失时取源文件名。
    static func applicationURL(_ entries: [Any], home: String, resolvedTarget: String? = nil) -> URL? {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if let target = resolvedTarget ?? entries.lazy.compactMap({ ($0 as? [String: Any])?["target"] as? String }).first {
            guard target.hasSuffix(".app") else { return nil }
            if target.hasPrefix("/") { return URL(fileURLWithPath: target).standardizedFileURL }
            if target.hasPrefix("~/") {
                return URL(fileURLWithPath: home + target.dropFirst()).standardizedFileURL
            }
            let resolved = applications.appendingPathComponent(target).standardizedFileURL
            // 相对 target 不能借助 .. 跳出 /Applications。
            return resolved.path.hasPrefix(applications.path + "/") ? resolved : nil
        }
        guard let source = entries.first as? String, source.hasSuffix(".app") else { return nil }
        return applications.appendingPathComponent(URL(fileURLWithPath: source).lastPathComponent)
    }

    private static func validToken(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+_.-/")
        guard !value.isEmpty, value.utf8.count <= 255, value.first != "-", !value.hasPrefix("/"),
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
