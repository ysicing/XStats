// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import LocalAuthentication
import Security

/// Claude 登录钥匙串的只读入口。必须在应用初始化 UI、偏好与后台服务之前调用。
public enum ClaudeKeychainReader {
    private static let argument = "--read-claude-keychain"

    /// 仅专用子进程读取凭据，返回令牌到匿名管道后退出，不修改凭据或访问控制。
    public static func runIfRequested() {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == argument else { return }
        // 外部程序不能借用 XStats 已获准的钥匙串身份获取令牌。
        // 只接受由同一代码身份的 XStats 父进程启动的读取请求。
        guard hasMatchingCodeIdentity(pid: getppid()) else { exit(1) }
        // LAContext 只约束数据保护钥匙串；传统登录钥匙串使用进程级开关。
        // 因此必须隔离到同一签名可执行文件的子进程，不能暂时关闭主进程的授权交互。
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(1) }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecAttrAccount: NSUserName(),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { exit(1) }
        do {
            let token = try ClaudeQuotaCredentials.parse(data).token
            try FileHandle.standardOutput.write(contentsOf: Data(token.utf8))
            exit(0)
        } catch AIQuotaFailure.unauthorized { exit(2) }
        catch { exit(1) }
    }

    static func hasMatchingCodeIdentity(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var ownCode: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var caller: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary,
                                            [], &caller) == errSecSuccess, let caller else { return false }
        return SecCodeCheckValidity(caller, [], requirement) == errSecSuccess
    }

    static func read() async throws -> String {
        guard let executable = Bundle.main.executableURL else { throw AIQuotaFailure.notConfigured }
        let cancellation = KeychainReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try readToken(using: executable, arguments: [argument],
                                      isCancelled: { cancellation.isSet })
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// 输出和整个进程生命周期均有界；凭据不经过命令行参数、日志或磁盘。
    static func readToken(using executable: URL, arguments: [String], timeout: Duration = .seconds(5),
                          isCancelled: () -> Bool = { false }) throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                // GCD 线程没有 RunLoop，不使用可能错过退出通知的 waitUntilExit()。
                let reapDeadline = clock.now.advanced(by: .seconds(2))
                while process.isRunning && clock.now < reapDeadline {
                    if kill(process.processIdentifier, 0) == -1 && errno == ESRCH { break }
                    usleep(10_000)
                }
            }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        if isCancelled() { throw CancellationError() }
        do { try process.run() } catch { throw AIQuotaFailure.notConfigured }
        // 关闭父进程的写端，否则子进程退出后读端仍收不到 EOF。
        try output.fileHandleForWriting.close()
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                events: Int16(POLLIN | POLLHUP), revents: 0)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if isCancelled() { throw CancellationError() }
            guard clock.now < deadline else { throw AIQuotaFailure.network }
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw AIQuotaFailure.network }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AIQuotaFailure.network }
            if count == 0 { break }
            guard buffer.count + count <= 65_536 else { throw AIQuotaFailure.notConfigured }
            buffer.append(contentsOf: chunk.prefix(count))
        }
        // EOF 不保证进程已退出；仍使用同一截止时间，不能在半途退出时接受令牌。
        while process.isRunning {
            if isCancelled() { throw CancellationError() }
            guard clock.now < deadline else { throw AIQuotaFailure.network }
            usleep(10_000)
        }
        if isCancelled() { throw CancellationError() }
        guard clock.now < deadline else { throw AIQuotaFailure.network }
        if process.terminationStatus == 2 { throw AIQuotaFailure.unauthorized }
        guard process.terminationStatus == 0, let token = String(data: buffer, encoding: .utf8),
              !token.isEmpty else { throw AIQuotaFailure.notConfigured }
        return token
    }
}

private final class KeychainReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isSet: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
