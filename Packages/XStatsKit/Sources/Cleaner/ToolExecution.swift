// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Darwin
import Localization

public struct ToolRunResult: Sendable {
    public let status: Int32
    public let output: String
}

public enum ToolExecutionError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case failed(tool: String, status: Int32, output: String)
    case timedOut(String)
    case outputTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let tool):
            tr("未找到 \(tool)，无法安全清理")
        case .timedOut(let tool): tr("\(tool) 执行超时，请稍后重试")
        case .outputTooLarge(let tool): tr("\(tool) 输出过大，请在终端检查")
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
    static func run(_ name: String, arguments: [String], home: String,
                    timeout: TimeInterval = 60, outputLimit: Int = 2_000_000) async throws -> ToolRunResult {
        try Task.checkCancellation()
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
        if name == "brew" {
            for key in ["HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_AUTOREMOVE", "HOMEBREW_NO_ANALYTICS",
                        "HOMEBREW_NO_ENV_HINTS", "HOMEBREW_NO_COLOR", "NONINTERACTIVE"] {
                environment[key] = "1"
            }
            environment["LC_ALL"] = "en_US.UTF-8"
        }
        process.environment = environment

        if name == "brew" {
            return try await runHomebrew(process, timeout: timeout, outputLimit: outputLimit)
        }

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

    /// 预览需要完整输出才能解析。写临时文件避免管道堵塞，同时限制大小、执行时间并响应取消。
    private static func runHomebrew(_ process: Process, timeout: TimeInterval, outputLimit: Int) async throws -> ToolRunResult {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-brew-\(UUID())")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer {
            stop(process)
            try? handle.close()
        }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() } catch {
            throw ToolExecutionError.failed(tool: "brew", status: -1, output: error.localizedDescription)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ToolExecutionError.timedOut("brew") }
            let size = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= outputLimit else { throw ToolExecutionError.outputTooLarge("brew") }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: outputLimit + 1) ?? Data()
        guard data.count <= outputLimit else { throw ToolExecutionError.outputTooLarge("brew") }
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ToolExecutionError.failed(tool: "brew", status: process.terminationStatus,
                                            output: String(output.prefix(2_000)))
        }
        return ToolRunResult(status: process.terminationStatus, output: output)
    }

    /// 只结束本次启动的进程；取消后仍给予短暂退出时间，防止清理子进程留在后台。
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
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
