// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Dispatch
import Foundation

/// 通过已登录的 Codex CLI 读取额度，让 CLI 自行刷新凭据。
enum CodexAppServerQuotaClient {
    static func fetch() async throws -> AIQuotaSnapshot {
        guard let executable = executableURL() else { throw AIQuotaFailure.notConfigured }
        // 读取最长阻塞 12 秒，放到 GCD 线程执行，不占用 Swift 并发的协作线程池
        let cancelled = CancellationFlag()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try readRateLimits(using: executable, isCancelled: { cancelled.isSet })
                    })
                }
            }
        } onCancel: {
            cancelled.set()
        }
        return try parse(response, now: Date())
    }

    static func parse(_ data: Data, now: Date) throws -> AIQuotaSnapshot {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = message["result"] as? [String: Any] else { throw AIQuotaFailure.invalidResponse }
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = buckets?["codex"] as? [String: Any]
                ?? result["rateLimits"] as? [String: Any] else { throw AIQuotaFailure.invalidResponse }

        // 每种窗口只保留一个，避免界面按窗口类型出现重复项
        var selected: [AIQuotaKind: (window: AIQuotaWindow, exact: Bool)] = [:]
        for field in ["primary", "secondary"] {
            guard let window = limits[field] as? [String: Any],
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue,
                  used.isFinite, (0...100).contains(used) else { continue }
            let kind: AIQuotaKind
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            switch minutes {
            case 300: kind = .session
            case 10_080: kind = .weekly
            case nil: kind = field == "primary" ? .session : .weekly
            default: continue
            }
            let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let exact = minutes != nil
            // 同类只保留一个：先到的 primary 优先，只有未标注时长的才被明确时长的替换
            if selected[kind] == nil || (exact && selected[kind]?.exact == false) {
                selected[kind] = (AIQuotaWindow(kind: kind, usedPercent: used, resetsAt: reset), exact)
            }
        }
        let windows = [AIQuotaKind.session, .weekly].compactMap { selected[$0]?.window }
        guard !windows.isEmpty else { throw AIQuotaFailure.invalidResponse }
        return AIQuotaSnapshot(provider: .codex, windows: windows, fetchedAt: now)
    }

    private static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fixed = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
        ]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { String($0) + "/codex" }
        return (fixed + path).first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    /// stdio JSONL：先 initialize，再等确认后读取 rate limits。进程始终有截止时间。
    static func readRateLimits(using executable: URL, isCancelled: () -> Bool = { false }) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        // CLI 可能随时退出；只抑制此管道的 SIGPIPE，避免一次额度查询终止主应用。
        guard Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw AIQuotaFailure.network
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw AIQuotaFailure.notConfigured }
        defer {
            if process.isRunning {
                process.terminate()
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }

        func send(_ message: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: message)
            do { try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A])) }
            catch { throw AIQuotaFailure.network }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        try send(["method": "initialize", "id": 0,
                  "params": ["clientInfo": ["name": "xstats", "title": "XStats", "version": version]]])

        let deadline = DispatchTime.now().uptimeNanoseconds + 12_000_000_000
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                events: Int16(POLLIN | POLLHUP), revents: 0)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if isCancelled() { throw CancellationError() }
            let instant = DispatchTime.now().uptimeNanoseconds
            guard instant < deadline else { throw AIQuotaFailure.network }
            let waitMs = Int32(max(1, min((deadline - instant) / 1_000_000, 1_000)))
            let ready = Darwin.poll(&descriptor, 1, waitMs)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw AIQuotaFailure.network }
            let count = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor.fd, bytes.baseAddress, bytes.count)
            }
            guard count > 0, buffer.count + count <= 1_048_576 else { throw AIQuotaFailure.network }
            buffer.append(contentsOf: chunk.prefix(count))

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if id == 0 {
                    guard message["result"] != nil else { throw AIQuotaFailure.network }
                    try send(["method": "initialized"])
                    try send(["method": "account/rateLimits/read", "id": 1])
                } else if id == 1 {
                    guard message["result"] != nil else { throw AIQuotaFailure.network }
                    return line
                }
            }
        }
    }
}

/// 在 GCD 线程上轮询的取消标记
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
