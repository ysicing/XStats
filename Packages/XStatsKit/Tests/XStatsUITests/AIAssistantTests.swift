// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Testing
@testable import XStatsUI
#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite struct AIAssistantTests {
    @MainActor @Test func ineligibleModelDoesNotClaimMacHardwareIsUnsupported() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability {
            #expect(ProcessExplainer.appleAvailability == tr("Apple 智能本机模型当前不可用。"))
        }
        #endif
    }

    @MainActor @Test func forcingUnselectedCLIIsRejectedBeforeReadingProcessFacts() {
        let name = "AIAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let config = AIAssistantConfiguration(defaults: defaults)
        config.fallbackChoice = .none
        let explainer = ProcessExplainer(configuration: config)
        let subject = ProcessExplainer.Subject(pid: 0, name: "Example", displayName: "Example",
            executablePath: "/private/sensitive/Example", appBundlePath: nil,
            cpu: nil, memory: nil, networkRate: nil)
        explainer.explain(subject, using: .codex)
        if case .failed(let message) = explainer.phase {
            #expect(!message.isEmpty)
        } else {
            Issue.record("Unselected CLI must be rejected synchronously")
        }
    }
    @MainActor @Test func selectingFallbackAuthorizesItOnlyForAppleUnavailability() {
        let name = "AIAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let config = AIAssistantConfiguration(defaults: defaults)
        #expect(config.fallbackChoice == .ask)
        #expect(config.authorizedFallback == nil)
        config.fallbackChoice = .codex
        #expect(config.authorizedFallback == .codex)
        config.provider = .claude
        #expect(config.authorizedFallback == nil)
        config.provider = .apple
        config.enabled = false
        #expect(config.authorizedFallback == nil)
        config.enabled = true
        config.fallbackChoice = .none
        #expect(config.authorizedFallback == nil)
        #expect(AIAssistantConfiguration(defaults: defaults).fallbackChoice == .none)
        // “不用备用”是明确选择，不能退化回默认的“遇到时询问”。
        config.fallbackChoice = .ask
        #expect(AIAssistantConfiguration(defaults: defaults).fallbackChoice == .ask)
    }

    @Test func earlyCLIExitCannotTerminateTheHostWithBrokenPipe() async {
        do {
            for try await _ in AssistantCLI.stream(executable: URL(fileURLWithPath: "/usr/bin/false"),
                provider: .codex, model: "", prompt: "synthetic facts") {}
            Issue.record("Expected CLI failure")
        } catch { /* 错误应交回调用方，而不是让 SIGPIPE 杀死测试宿主。 */ }
    }

    @Test func authenticationDiagnosticsNeverExposeRawSecrets() {
        let secret = "example-secret-that-must-not-escape"
        let error = AssistantCLIError.classify("401 unauthorized Bearer " + secret)
        #expect(!error.localizedDescription.contains(secret))
        #expect(error.localizedDescription.contains("登录"))
    }
    @MainActor @Test func providerChoiceAndPathsPersistLocally() {
        let name = "AIAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let config = AIAssistantConfiguration(defaults: defaults)
        #expect(config.provider == .apple)
        #expect(config.fallbackChoice == .ask)
        config.provider = .claude
        config.fallbackChoice = .codex
        config.claudePath = "/tmp/claude"
        let restored = AIAssistantConfiguration(defaults: defaults)
        #expect(restored.provider == .claude)
        #expect(restored.fallbackChoice == .codex)
        #expect(restored.claudePath == "/tmp/claude")
    }

    @Test func commandArgumentsKeepPromptsOutAndDisableExecution() {
        let codex = AssistantCLI.arguments(provider: .codex, model: "test-model")
        #expect(codex.contains("--ignore-user-config"))
        #expect(codex.contains("--ephemeral"))
        #expect(codex.contains("read-only"))
        for name in ["shell_tool", "hooks", "plugins", "remote_plugin", "multi_agent", "view_image", "apps"] {
            let index = codex.firstIndex(of: name)!
            #expect(codex[index - 1] == "--disable")
        }
        let claude = AssistantCLI.arguments(provider: .claude, model: "")
        #expect(claude.contains("--safe-mode"))
        #expect(claude.contains("--strict-mcp-config"))
        #expect(claude[claude.firstIndex(of: "--tools")! + 1] == "")
        #expect(!claude.contains("--dangerously-skip-permissions"))
    }

    @Test func decodesStreamsWithoutRepeatingClaudeFinalText() throws {
        var claude = AssistantOutputDecoder(provider: .claude)
        let delta = Data(#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"hello"}}}"#.utf8)
        #expect(try claude.consume(delta) == "hello")
        #expect(try claude.consume(Data(#"{"type":"result","result":"hello","is_error":false}"#.utf8)) == "hello")
        var codex = AssistantOutputDecoder(provider: .codex)
        #expect(try codex.consume(Data(#"{"type":"item.completed","item":{"type":"agent_message","text":"answer"}}"#.utf8)) == "answer")
        #expect(throws: (any Error).self) {
            try codex.consume(Data(#"{"type":"item.started","item":{"type":"command_execution"}}"#.utf8))
        }
    }

    @Test func processFactsDoNotSendUserDirectoryOrBundlePath() {
        let subject = ProcessExplainer.Subject(pid: 0, name: "Example", displayName: "Example",
            executablePath: "/Users/private-user/private-project/Example",
            appBundlePath: nil, cpu: 0.5, memory: nil, networkRate: nil)
        let facts = ProcessExplainer.facts(for: subject, redactPaths: true)
        #expect(!facts.contains("private-user"))
        #expect(!facts.contains("private-project"))
        #expect(facts.contains("Example"))
    }

    @Test func runsFixtureCLIWithStdinAndStructuredOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("cli")
        try Data("""
        #!/bin/sh
        while IFS= read -r line; do :; done
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"fixture answer"}}'
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var result = ""
        for try await text in AssistantCLI.stream(executable: script, provider: .codex, model: "", prompt: "synthetic facts") {
            result = text
        }
        #expect(result == "fixture answer")
    }

    @Test func timeoutTerminatesOwnedCLI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("cli")
        try Data("#!/bin/sh\nwhile :; do :; done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        do {
            for try await _ in AssistantCLI.stream(executable: script, provider: .codex, model: "", prompt: "test", timeout: 0.1) {}
            Issue.record("Expected timeout")
        } catch AssistantCLIError.timeout { }
    }
}
