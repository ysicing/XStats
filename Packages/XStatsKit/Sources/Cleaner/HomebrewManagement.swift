// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct HomebrewPackage: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable { case formula, cask }
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
    public var version: String { installedVersions.joined(separator: ", ") }
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
        let prefix = try await DeveloperToolRunner.run("brew", arguments: ["--prefix"], home: home).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.hasPrefix("/"), !prefix.contains("\n") else { throw InventoryError.invalidOutput }
        let result = try await DeveloperToolRunner.run("brew", arguments: ["info", "--json=v2", "--installed"],
                                                      home: home, outputLimit: 16_000_000)
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
            environmentOverrides: ["HOMEBREW_NO_INSTALL_CLEANUP": "1"], previewTimeout: 1_800)
    }

    static func arguments(for action: Action, package: HomebrewPackage) throws -> [String] {
        guard validToken(package.name), !(action == .upgrade && package.pinned) else { throw InventoryError.invalidPackage }
        return [action.rawValue, package.kind == .formula ? "--formula" : "--cask", package.name]
    }

    /// 解析完整、限量的原生清单；验证操作所用的包标识，未知安装路径保持空值。
    public static func parse(_ output: String, prefix: URL) throws -> [HomebrewPackage] {
        // brew 的警告写入 stderr；现有 runner 合并输出。只解析完整的 JSON 对象，输出截断由 runner 拒绝。
        guard let first = output.firstIndex(of: "{"), let last = output.lastIndex(of: "}"), first <= last,
              let object = try JSONSerialization.jsonObject(with: Data(output[first...last].utf8)) as? [String: Any],
              let formulae = object["formulae"] as? [[String: Any]], let casks = object["casks"] as? [[String: Any]],
              formulae.count + casks.count <= 10_000 else { throw InventoryError.invalidOutput }
        var packages: [HomebrewPackage] = []
        for formula in formulae {
            try Task.checkCancellation()
            guard let name = formula["full_name"] as? String, validToken(name),
                  let short = formula["name"] as? String, validToken(short), !short.contains("/"),
                  let installed = formula["installed"] as? [[String: Any]] else { throw InventoryError.invalidOutput }
            let versions = installed.compactMap { $0["version"] as? String }
            guard !versions.isEmpty, versions.allSatisfy({ validToken($0) && !$0.contains("/") }) else { throw InventoryError.invalidOutput }
            let stable = (formula["versions"] as? [String: Any])?["stable"] as? String
            let revision = formula["revision"] as? Int ?? 0
            let latest = stable.map { revision > 0 ? "\($0)_\(revision)" : $0 }
            packages.append(HomebrewPackage(name: name, displayName: short, kind: .formula, installedVersions: versions,
                latestVersion: latest, outdated: formula["outdated"] as? Bool ?? false, pinned: formula["pinned"] as? Bool ?? false,
                installationURLs: versions.map { prefix.appendingPathComponent("Cellar/\(short)/\($0)") }, applicationURLs: []))
        }
        for cask in casks {
            try Task.checkCancellation()
            guard let name = cask["full_token"] as? String, validToken(name),
                  let installed = cask["installed"] as? String else { throw InventoryError.invalidOutput }
            var applications: [URL] = []
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                guard let entries = artifact["app"] as? [Any] else { continue }
                let explicit = artifact["target"] as? String ?? (entries.last as? [String: Any])?["target"] as? String
                if let path = explicit, path.hasPrefix("/"), path.hasSuffix(".app") {
                    applications.append(URL(fileURLWithPath: path))
                } else if let path = entries.first as? String, path.hasSuffix(".app") {
                    applications.append(URL(fileURLWithPath: "/Applications").appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent))
                }
            }
            packages.append(HomebrewPackage(name: name, displayName: (cask["name"] as? [String])?.first ?? name, kind: .cask,
                installedVersions: [installed], latestVersion: cask["version"] as? String,
                outdated: cask["outdated"] as? Bool ?? false, pinned: cask["pinned"] as? Bool ?? false,
                installationURLs: applications, applicationURLs: applications))
        }
        guard Set(packages.map(\.id)).count == packages.count else { throw InventoryError.invalidOutput }
        return packages.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func validToken(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+_.-/")
        guard !value.isEmpty, value.utf8.count <= 255, value.first != "-", !value.hasPrefix("/"),
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
