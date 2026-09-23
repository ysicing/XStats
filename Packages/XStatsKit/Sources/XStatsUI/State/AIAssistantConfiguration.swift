// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Observation

public enum AssistantProvider: String, CaseIterable, Sendable, Identifiable {
    case apple, codex, claude
    public var id: Self { self }
    var title: String {
        switch self { case .apple: "Apple 智能"; case .codex: "Codex CLI"; case .claude: "Claude Code" }
    }
}

public enum AssistantFallbackChoice: String, CaseIterable, Sendable {
    case ask, none, codex, claude
}

/// CLI 路径和服务选择仅存本机，不随 WebDAV 设置备份迁移。
@MainActor @Observable
public final class AIAssistantConfiguration {
    @ObservationIgnored private let defaults: UserDefaults
    public var enabled: Bool { didSet { defaults.set(enabled, forKey: "assistant.enabled") } }
    public var provider: AssistantProvider { didSet { defaults.set(provider.rawValue, forKey: "assistant.provider") } }
    /// ask 与明确选择“不使用备用”分开存储，首次提示后不再反复询问。
    public var fallbackChoice: AssistantFallbackChoice {
        didSet { defaults.set(fallbackChoice.rawValue, forKey: "assistant.fallback") }
    }
    public var codexPath: String { didSet { defaults.set(codexPath, forKey: "assistant.codexPath") } }
    public var claudePath: String { didSet { defaults.set(claudePath, forKey: "assistant.claudePath") } }
    public var codexModel: String { didSet { defaults.set(codexModel, forKey: "assistant.codexModel") } }
    public var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "assistant.claudeModel") } }

    var authorizedFallback: AssistantProvider? {
        guard enabled, provider == .apple else { return nil }
        switch fallbackChoice {
        case .codex: return .codex
        case .claude: return .claude
        case .ask, .none: return nil
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "assistant.enabled") as? Bool ?? true
        provider = defaults.string(forKey: "assistant.provider").flatMap(AssistantProvider.init(rawValue:)) ?? .apple
        fallbackChoice = defaults.string(forKey: "assistant.fallback")
            .flatMap(AssistantFallbackChoice.init(rawValue:)) ?? .ask
        codexPath = defaults.string(forKey: "assistant.codexPath") ?? ""
        claudePath = defaults.string(forKey: "assistant.claudePath") ?? ""
        codexModel = defaults.string(forKey: "assistant.codexModel") ?? ""
        claudeModel = defaults.string(forKey: "assistant.claudeModel") ?? ""
    }
}
