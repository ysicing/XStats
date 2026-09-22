// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

public struct ToolRunResult: Sendable {
    public let status: Int32
    public let output: String
}

public enum ToolExecutionError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case failed(tool: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let tool):
            tr("未找到 \(tool)，无法安全清理")
        case .failed(let tool, let status, let output):
            output.isEmpty
                ? tr("\(tool) 清理失败（退出码 \(status)）")
                : tr("\(tool) 清理失败（退出码 \(status)）：\(output)")
        }
    }
}

enum DeveloperToolRunner {
    /// 只从常见的用户工具目录和系统工具目录解析，避免依赖 GUI 进程通常不完整的 PATH。
    static func executable(named name: String, home: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return searchDirectories(home: home)
            .map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 外部工具可能执行较久；放到并发执行器，避免阻塞调用它的主 Actor。
    @concurrent
    static func run(_ name: String, arguments: [String], home: String) async throws -> ToolRunResult {
        guard let executable = executable(named: name, home: home) else {
            throw ToolExecutionError.unavailable(name)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["PATH"] = ([executable.deletingLastPathComponent()] + searchDirectories(home: home))
            .map(\.path).uniqued().joined(separator: ":")
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw ToolExecutionError.failed(tool: name, status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ToolExecutionError.failed(tool: name, status: process.terminationStatus,
                                            output: String(output.prefix(2_000)))
        }
        return ToolRunResult(status: process.terminationStatus, output: output)
    }

    private static func searchDirectories(home: String) -> [URL] {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        var directories = [
            homeURL.appendingPathComponent(".local/bin"),
            homeURL.appendingPathComponent(".cargo/bin"),
            homeURL.appendingPathComponent(".bun/bin"),
            homeURL.appendingPathComponent(".volta/bin"),
            homeURL.appendingPathComponent(".asdf/shims"),
            homeURL.appendingPathComponent(".local/share/mise/shims"),
        ]

        let nvmRoot = homeURL.appendingPathComponent(".nvm/versions/node")
        let nvmVersions = ((try? FileManager.default.contentsOfDirectory(
            at: nvmRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }
        directories += nvmVersions.map { $0.appendingPathComponent("bin") }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        return directories.uniqued()
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
