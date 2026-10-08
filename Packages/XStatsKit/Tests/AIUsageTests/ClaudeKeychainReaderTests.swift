// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import AIUsage
import Darwin
import Foundation
import Testing

@Suite struct ClaudeKeychainReaderTests {
    @Test func acceptsOwnCodeIdentityAndRejectsAnUnrelatedProcess() throws {
        #expect(ClaudeKeychainReader.hasMatchingCodeIdentity(pid: getpid()))
        #expect(!ClaudeKeychainReader.hasMatchingCodeIdentity(pid: 0))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        #expect(!ClaudeKeychainReader.hasMatchingCodeIdentity(pid: process.processIdentifier))
    }

    @Test func readsTokenOnlyAfterSuccessfulExit() throws {
        let token = try ClaudeKeychainReader.readToken(using: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf test-token"], timeout: .seconds(2))
        #expect(token == "test-token")
    }

    @Test func rejectsDeniedAndExpiredCredentials() {
        for (status, failure) in [(1, AIQuotaFailure.notConfigured), (2, .unauthorized)] {
            #expect(throws: failure) {
                try ClaudeKeychainReader.readToken(using: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf unusable-token; exit \(status)"], timeout: .seconds(2))
            }
        }
    }

    @Test func boundsOutputAndWaitAfterClosingStdout() {
        #expect(throws: AIQuotaFailure.notConfigured) {
            try ClaudeKeychainReader.readToken(using: URL(fileURLWithPath: "/usr/bin/head"),
                arguments: ["-c", "65537", "/dev/zero"], timeout: .seconds(2))
        }
        let started = ContinuousClock.now
        #expect(throws: AIQuotaFailure.network) {
            try ClaudeKeychainReader.readToken(using: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec 1>&-; exec /bin/sleep 10"], timeout: .milliseconds(150))
        }
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test func cancellationStopsAnActiveReader() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let started = ContinuousClock.now
        #expect(throws: CancellationError.self) {
            try ClaudeKeychainReader.readToken(using: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 10", "reader", pidFile.path], timeout: .seconds(5),
                isCancelled: { started.duration(to: .now) > .milliseconds(100) })
        }
        #expect(started.duration(to: .now) < .seconds(3))
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        let status = kill(pid, 0)
        let error = errno
        // 测试失败也只清理本用例启动的进程。
        if status == 0 { kill(pid, SIGKILL) }
        #expect(status == -1 && error == ESRCH)
    }

    @Test func keepsFilePriorityAndFileFailureOnDeniedKeychain() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = root.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"file-token"}}"#.utf8).write(to: file)
        let token = try await ClaudeQuotaCredentials.load(environment: [:], home: home,
            keychain: { throw AIQuotaFailure.notConfigured })
        #expect(token == "file-token")
        try Data(#"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1}}"#.utf8).write(to: file)
        await #expect(throws: AIQuotaFailure.unauthorized) {
            try await ClaudeQuotaCredentials.load(environment: [:], home: home,
                keychain: { throw AIQuotaFailure.notConfigured })
        }
        let fallback = try await ClaudeQuotaCredentials.load(environment: [:], home: home,
            keychain: { "keychain-token" })
        #expect(fallback == "keychain-token")
    }
}
