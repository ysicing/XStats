// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Security

/// 只从应用本身与受限的嵌套 bundle 中收集身份，不用开发团队或通用 helper 名称推断归属。
struct AppUninstallIdentity: Sendable {
    let identifiers: Set<String>
    let names: Set<String>
    let applicationGroups: Set<String>
    let teamIdentifier: String?

    init(identifiers: Set<String>, names: Set<String>, applicationGroups: Set<String> = [], teamIdentifier: String? = nil) {
        self.identifiers = Set(identifiers.compactMap(Self.validIdentifier))
        self.names = Set(names.compactMap(Self.validName))
        self.applicationGroups = Set(applicationGroups.compactMap(Self.validIdentifier))
        self.teamIdentifier = teamIdentifier.flatMap(Self.validTeamIdentifier)
    }

    init(app: InstalledApp) {
        var identifiers = Set([app.bundleIdentifier])
        var names = Set([app.name, app.url.deletingPathExtension().lastPathComponent])
        var groups = Set<String>()
        var teamIdentifier: String?

        // 父目录的系统别名（例如 /var）可以规范化，应用本身与内部路径不接受符号链接。
        if !Task.isCancelled, let values = try? app.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isDirectory == true, values.isSymbolicLink != true {
            let root = app.url.resolvingSymlinksInPath().standardizedFileURL
            if let metadata = Self.metadata(at: root, inside: root) {
                if let identifier = metadata["CFBundleIdentifier"] as? String { identifiers.insert(identifier) }
                for key in ["CFBundleName", "CFBundleDisplayName"] {
                    if let name = metadata[key] as? String { names.insert(name) }
                }
            }
            if let signature = Self.signature(at: root) {
                groups.formUnion(signature.groups)
                teamIdentifier = signature.teamIdentifier
            }
            for bundle in Self.embeddedBundles(in: root) {
                if Task.isCancelled { break }
                if let metadata = Self.metadata(at: bundle, inside: root),
                   let identifier = metadata["CFBundleIdentifier"] as? String {
                    identifiers.insert(identifier)
                    if let signature = Self.signature(at: bundle) { groups.formUnion(signature.groups) }
                }
            }
        }

        self.init(identifiers: identifiers, names: names, applicationGroups: groups, teamIdentifier: teamIdentifier)
    }

    static func validIdentifier(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 255 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let alphanumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard parts.count >= 2, parts.allSatisfy({ part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(allowed.contains)
                && part.unicodeScalars.contains(where: alphanumeric.contains)
        }) else { return nil }
        return value
    }

    static func validName(_ value: String) -> String? {
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let name = value.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\") else { return nil }
        return name
    }

    static func validTeamIdentifier(_ value: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard !value.isEmpty, value.utf8.count <= 64, value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    static func applicationGroups(from entitlements: [String: Any]) -> Set<String> {
        let groups = entitlements["com.apple.security.application-groups"] as? [Any] ?? []
        return Set(groups.compactMap { ($0 as? String).flatMap(validIdentifier) })
    }

    /// 必须实际位于根 bundle 内，且整个内部路径不能经由符号链接。
    static func isSafeURL(_ url: URL, inside root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/"),
              url.resolvingSymlinksInPath().standardizedFileURL.path == path,
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return false }
        return true
    }

    static func metadata(at bundle: URL, inside root: URL) -> [String: Any]? {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        guard isSafeURL(bundle, inside: root), isSafeURL(url, inside: root),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return plist as? [String: Any]
    }

    static func embeddedBundles(in root: URL) -> [URL] {
        let locations = ["Contents/Frameworks", "Contents/XPCServices", "Contents/PlugIns"]
        let ignoredDirectories: Set<String> = ["Resources", "_CodeSignature", "MacOS", "Headers", "Modules"]
        var pending = locations.map { (url: root.appendingPathComponent($0), depth: 0) }
        var visited = Set<String>()
        var results: [URL] = []
        var examined = 0
        let manager = FileManager.default

        // 取消可返回部分身份，外层扫描随后抛错，禁止发布部分候选。
        while !Task.isCancelled, !pending.isEmpty, examined < 512, results.count < 64 {
            let (directory, depth) = pending.removeFirst()
            guard depth <= 8, isSafeURL(directory, inside: root), visited.insert(directory.path).inserted,
                  let children = try? manager.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) else { continue }
            for child in children.sorted(by: { $0.path < $1.path }) {
                guard !Task.isCancelled, examined < 512, results.count < 64 else { break }
                examined += 1
                guard isSafeURL(child, inside: root),
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else { continue }
                if ["app", "xpc", "appex"].contains(child.pathExtension.lowercased()),
                   let info = metadata(at: child, inside: root), let identifier = info["CFBundleIdentifier"] as? String,
                   validIdentifier(identifier) != nil {
                    results.append(child)
                }
                if depth < 8, !ignoredDirectories.contains(child.lastPathComponent) {
                    pending.append((child, depth + 1))
                }
            }
        }
        return results
    }

    private struct Signature {
        let groups: Set<String>
        let teamIdentifier: String?
    }

    private static func signature(at url: URL) -> Signature? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, validationFlags, nil) == errSecSuccess else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let team = (dictionary[kSecCodeInfoTeamIdentifier as String] as? String).flatMap(validTeamIdentifier)
        return Signature(groups: applicationGroups(from: entitlements), teamIdentifier: team)
    }
}
