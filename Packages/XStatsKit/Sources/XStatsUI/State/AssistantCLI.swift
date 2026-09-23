// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Darwin

enum AssistantCLIError: LocalizedError {
    case missing, failed(Int32), timeout, excessiveOutput, authentication, rateLimited, network, unsupported
    var errorDescription: String? {
        switch self {
        case .missing: "没有找到可执行的 CLI，请在 AI 助手设置中选择路径。"
        case .failed(let status): "CLI 调用失败（退出码 \(status)）。请检查 CLI 版本和登录状态后重试。"
        case .timeout: "AI 请求超时，请稍后重试。"
        case .excessiveOutput: "CLI 返回内容过多，已停止本次请求。"
        case .authentication: "CLI 尚未登录或登录已过期，请在终端重新登录。"
        case .rateLimited: "AI 服务限流或额度不足，请稍后重试。"
        case .network: "无法连接 AI 服务，请检查网络或 CLI 配置。"
        case .unsupported: "当前 CLI 不支持所需的隔离参数，请升级 CLI。"
        }
    }
    static func classify(_ text: String, status: Int32 = 1) -> Self {
        let text = text.lowercased()
        if ["not logged", "unauthorized", "authentication", "401", "token expired"].contains(where: text.contains) { return .authentication }
        if ["429", "rate limit", "quota", "usage limit"].contains(where: text.contains) { return .rateLimited }
        if ["unknown option", "unexpected argument", "unknown feature", "unrecognized"].contains(where: text.contains) { return .unsupported }
        if ["connection", "network", "timed out", "dns", "tls"].contains(where: text.contains) { return .network }
        return .failed(status)
    }
}

enum AssistantCLI {
    static func resolve(_ provider: AssistantProvider, override: String) -> URL? {
        let fm = FileManager.default
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let path = (trimmed as NSString).expandingTildeInPath
            return path.hasPrefix("/") && fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let name = provider.rawValue
        let home = fm.homeDirectoryForCurrentUser
        var folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let versions = home.appendingPathComponent(".nvm/versions/node")
        if let installed = try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) {
            folders += installed.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                .map { $0.appendingPathComponent("bin").path }
        }
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    static func arguments(provider: AssistantProvider, model: String) -> [String] {
        var args: [String]
        if provider == .codex {
            args = ["exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                    "--skip-git-repo-check", "--sandbox", "read-only", "-c", "web_search=\"disabled\"",
                    "-c", "project_doc_max_bytes=0", "-c", "mcp_servers={}", "--enable", "skip_host_skill_discovery"]
            for feature in ["shell_tool", "unified_exec", "code_mode", "apps", "browser_use", "computer_use",
                            "image_generation", "skill_search", "hooks", "plugins", "remote_plugin", "skill_mcp_dependency_install",
                            "multi_agent", "view_image", "default_mode_request_user_input"] {
                args += ["--disable", feature]
            }
        } else {
            args = ["--print", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--no-session-persistence", "--safe-mode", "--tools", "", "--strict-mcp-config",
                    "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "", "--disable-slash-commands"]
        }
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { args += ["--model", selected] }
        if provider == .codex { args += ["-"] }
        return args
    }

    static func stream(executable: URL, provider: AssistantProvider, model: String, prompt: String,
                       timeout: TimeInterval = 60) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let box = AssistantProcessBox()
            let worker = Task.detached {
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XStats-AI-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments(provider: provider, model: model)
                    process.currentDirectoryURL = directory
                    var environment = ProcessInfo.processInfo.environment
                    environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
                    environment.removeValue(forKey: "CLAUDECODE")
                    environment.removeValue(forKey: "CODEX_THREAD_ID")
                    process.environment = environment
                    let input = Pipe(), output = Pipe(), errors = Pipe()
                    // CLI 若因不支持参数而立即退出，写入关闭的 stdin 应抛错，不能让 SIGPIPE 终止宿主应用。
                    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    process.standardInput = input; process.standardOutput = output
                    process.standardError = errors
                    try box.start(process)
                    let errorReader = DispatchGroup()
                    errorReader.enter()
                    DispatchQueue.global().async {
                        defer { errorReader.leave() }
                        while let data = try? errors.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                            box.recordDiagnostic(data)
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.cancel(timedOut: true) }
                    try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                    try input.fileHandleForWriting.close()
                    var pending = Data(), bytes = 0, text = ""
                    var decoder = AssistantOutputDecoder(provider: provider)
                    while let chunk = try output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                        try Task.checkCancellation()
                        bytes += chunk.count
                        guard bytes <= 1_048_576 else { box.cancel(); throw AssistantCLIError.excessiveOutput }
                        pending.append(chunk)
                        while let end = pending.firstIndex(of: 10) {
                            if let next = try decoder.consume(Data(pending[..<end])), next != text {
                                text = next; continuation.yield(text)
                            }
                            pending.removeSubrange(...end)
                        }
                    }
                    if !pending.isEmpty, let next = try decoder.consume(pending) { text = next; continuation.yield(text) }
                    process.waitUntilExit()
                    await withCheckedContinuation { continuation in
                        errorReader.notify(queue: .global()) { continuation.resume() }
                    }
                    try Task.checkCancellation()
                    if box.timedOut { throw AssistantCLIError.timeout }
                    guard process.terminationStatus == 0, !text.isEmpty else { throw box.failure(status: process.terminationStatus) }
                    continuation.finish()
                } catch {
                    box.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel(); box.cancel() }
        }
    }
}

/// Process 的启动/取消跨越读取线程和主线程；锁保护启动前取消及退出后 PID 重用边界。
private final class AssistantProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var expired = false
    private var diagnostic = Data()
    var timedOut: Bool { lock.withLock { expired } }
    func recordDiagnostic(_ data: Data) {
        lock.withLock {
            diagnostic.append(data)
            if diagnostic.count > 16_384 { diagnostic.removeFirst(diagnostic.count - 16_384) }
        }
    }
    func failure(status: Int32) -> AssistantCLIError {
        lock.withLock { .classify(String(decoding: diagnostic, as: UTF8.self), status: status) }
    }

    func start(_ process: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            self.process = process
            try process.run()
        }
    }
    func cancel(timedOut: Bool = false) {
        lock.withLock {
            cancelled = true
            guard let process, process.isRunning else { return }
            expired = expired || timedOut
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.withLock {
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

struct AssistantOutputDecoder {
    let provider: AssistantProvider
    private var text = ""
    init(provider: AssistantProvider) { self.provider = provider }

    mutating func consume(_ line: Data) throws -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let type = object["type"] as? String
        if type == "error" || type == "turn.failed" {
            throw AssistantCLIError.classify(String(decoding: line, as: UTF8.self))
        }
        if provider == .codex, let item = object["item"] as? [String: Any] {
            let itemType = item["type"] as? String
            if ["command_execution", "mcp_tool_call", "web_search", "file_change"].contains(itemType ?? "") {
                throw AssistantCLIError.failed(1)
            }
            if itemType == "agent_message", let value = item["text"] as? String { text = value; return text }
        }
        if provider == .claude {
            if type == "stream_event", let event = object["event"] as? [String: Any],
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let value = delta["text"] as? String { text += value; return text }
            if type == "result" {
                if object["is_error"] as? Bool == true {
                    throw AssistantCLIError.classify(String(decoding: line, as: UTF8.self))
                }
                if let result = object["result"] as? String { text = result; return text }
            }
        }
        return nil
    }
}
