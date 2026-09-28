// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Darwin
import Localization

public struct ToolRunResult: Sendable {
    public let status: Int32
    public let output: String
    /// 真实 Homebrew 清理的完整输出统计，避免截断诊断文本后丢失汇总。
    public let cleanupReport: CleanReport?

    public init(status: Int32, output: String, cleanupReport: CleanReport? = nil) {
        self.status = status
        self.output = output
        self.cleanupReport = cleanupReport
    }
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
                    previewTimeout: TimeInterval = 60, outputLimit: Int = 2_000_000) async throws -> ToolRunResult {
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
            if arguments.first == "cleanup", !arguments.contains("--dry-run") {
                // 真实清理可能已删除部分文件，不因超时或输出量中断；仍响应用户取消。
                return try await runHomebrewCleanup(process, outputLimit: outputLimit)
            }
            return try await runHomebrewPreview(process, timeout: previewTimeout, outputLimit: outputLimit)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            throw ToolExecutionError.failed(tool: name, status: -1, output: error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()
        let reader = pipe.fileHandleForReading
        // 读取任务自己在读完后关闭句柄：取消时外面不能在它还在 read 时关掉同一个 fd，
        // 否则读取会报错，或读到 fd 编号被系统复用后的其他文件。
        let outputTask = Task.detached(priority: .utility) {
            defer { try? reader.close() }
            var tail = Data()
            let limit = max(0, outputLimit)
            while let chunk = try readChunk(reader) {
                tail.append(chunk)
                if tail.count > limit { tail.removeFirst(tail.count - limit) }
            }
            return String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 正常退出时读到 EOF；取消时通知读取任务自行退出并关闭句柄
        defer {
            outputTask.cancel()
            stop(process)
        }
        while process.isRunning {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        let output = try await outputTask.value
        guard process.terminationStatus == 0 else {
            throw ToolExecutionError.failed(tool: name, status: process.terminationStatus,
                                            output: String(output.prefix(2_000)))
        }
        return ToolRunResult(status: process.terminationStatus, output: output)
    }

    /// 预览需要完整输出才能解析；超过限制时终止只读命令。
    private static func runHomebrewPreview(_ process: Process, timeout: TimeInterval, outputLimit: Int) async throws -> ToolRunResult {
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

    /// 持续排空管道，让清理执行到底；只保留有限的末尾诊断文本和逐行汇总。
    private static func runHomebrewCleanup(_ process: Process, outputLimit: Int) async throws -> ToolRunResult {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() } catch {
            throw ToolExecutionError.failed(tool: "brew", status: -1, output: error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()
        let reader = pipe.fileHandleForReading
        // 与 run 相同：句柄只由读取任务在读完后关闭，取消时不与读取竞争
        let outputTask = Task.detached(priority: .utility) {
            defer { try? reader.close() }
            return try readHomebrewCleanupOutput(reader, outputLimit: outputLimit)
        }
        defer {
            outputTask.cancel()
            stop(process)
        }
        while process.isRunning {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        let result = try await outputTask.value
        guard process.terminationStatus == 0 else {
            throw ToolExecutionError.failed(tool: "brew", status: process.terminationStatus,
                                            output: String(result.output.suffix(2_000)))
        }
        guard !result.hasInvalidSummary else { throw HomebrewCleanup.PreviewError.unsupportedOutput }
        return ToolRunResult(status: process.terminationStatus, output: result.output, cleanupReport: result.report)
    }

    private struct CleanupOutput: Sendable {
        let output: String
        let report: CleanReport
        let hasInvalidSummary: Bool
    }

    private static func readHomebrewCleanupOutput(_ reader: FileHandle, outputLimit: Int) throws -> CleanupOutput {
        var tail = Data()
        var line = [UInt8]()
        var lineTooLong = false
        var report = CleanReport()
        var hasInvalidSummary = false
        while let chunk = try readChunk(reader) {
            tail.append(chunk)
            if tail.count > outputLimit { tail.removeFirst(tail.count - max(0, outputLimit)) }
            for byte in chunk {
                if byte == 0x0A {
                    if !lineTooLong { recordHomebrewLine(line, report: &report, hasInvalidSummary: &hasInvalidSummary) }
                    line.removeAll(keepingCapacity: true)
                    lineTooLong = false
                } else if line.count < 64 * 1024 {
                    line.append(byte)
                } else {
                    // 跳过异常长的单行诊断输出，继续读取后续的 Homebrew 汇总行。
                    lineTooLong = true
                }
            }
        }
        if !line.isEmpty, !lineTooLong {
            recordHomebrewLine(line, report: &report, hasInvalidSummary: &hasInvalidSummary)
        }
        return CleanupOutput(output: String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                             report: report, hasInvalidSummary: hasInvalidSummary)
    }

    /// 限时轮询让取消能中断读取；孙进程继承管道写端时，阻塞式 read 可能一直等不到 EOF。
    private static func readChunk(_ reader: FileHandle) throws -> Data? {
        var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress, $0.count) }
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return Data(bytes.prefix(count))
        }
    }

    private static func recordHomebrewLine(_ bytes: [UInt8], report: inout CleanReport, hasInvalidSummary: inout Bool) {
        let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        do { try HomebrewCleanup.recordExecutionLine(line, report: &report) }
        catch { hasInvalidSummary = true }
    }

    /// 只结束本次启动的进程；取消后仍给予短暂退出时间，防止清理子进程留在后台。
    /// 不调用 `waitUntilExit()`：它靠当前线程的 RunLoop 接收退出通知，而这里跑在不驱动 RunLoop 的
    /// 并发线程上，错过通知就会永久等待（停止清理卡在“正在停止”）。改为有上限的轮询。
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        guard !waitForExit(process, seconds: 1) else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        // SIGKILL 无法被忽略，进程很快会被回收；仍设上限，不让调用方无限等待
        _ = waitForExit(process, seconds: 2)
    }

    /// 进程已退出返回 true。`kill(pid, 0)` 报 ESRCH 说明已被回收，不必再等 Foundation 更新 `isRunning`。
    private static func waitForExit(_ process: Process, seconds: Int) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            if Darwin.kill(process.processIdentifier, 0) != 0 && errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
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
