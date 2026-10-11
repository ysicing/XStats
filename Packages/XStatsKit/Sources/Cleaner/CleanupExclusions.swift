// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 本机排除路径同时保护自身、后代及其父候选，避免删除整个目录时连带删除保留项。
public enum CleanupExclusions {
    public static func normalized(_ paths: [String]) -> [String] {
        Array(Set(paths.filter {
            $0.hasPrefix("/") && $0.utf8.count <= 4096
                && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted().prefix(50).map { $0 }
    }

    public static func overlaps(_ url: URL, paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        let candidate = url.standardizedFileURL
        let candidates = [candidate.path, canonicalPath(candidate)]
        return paths.contains { path in
            let root = URL(fileURLWithPath: path).standardizedFileURL
            return [root.path, canonicalPath(root)].contains { excluded in
                candidates.contains { value in
                    excluded == "/" || value == excluded || value.hasPrefix(excluded + "/") || excluded.hasPrefix(value + "/")
                }
            }
        }
    }

    /// UI 只进行字符串关系判断；文件系统别名校验由后台扫描与执行负责。
    public static func overlapsLexically(_ url: URL, paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        let path = url.standardizedFileURL.path
        return paths.contains { excluded in
            excluded == "/" || path == excluded || path.hasPrefix(excluded + "/") || excluded.hasPrefix(path + "/")
        }
    }

    /// 不存在的子项也按最近存在的父目录解析别名，保留目录在删除或重建后仍受保护。
    private static func canonicalPath(_ url: URL) -> String {
        var parent = url
        var suffix: [String] = []
        while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
            suffix.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
        var resolved = parent.resolvingSymlinksInPath()
        for name in suffix.reversed() { resolved.appendPathComponent(name) }
        return resolved.standardizedFileURL.path
    }
}
