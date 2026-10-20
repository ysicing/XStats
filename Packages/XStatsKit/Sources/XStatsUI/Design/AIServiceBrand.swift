// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 订阅页面与菜单栏共用服务名称和标志；未知服务保留原名并使用通用图标。
enum AIServiceBrand {
  static let defaultMenuBarProviders = ["codex", "claude", "gemini", "grok"]
  static let menuBarOrder = defaultMenuBarProviders + ["copilot", "perplexity"]

  static func menuBarTitle(_ provider: String) -> String {
    title(provider)
  }

  static func logoName(_ provider: String) -> String? {
    switch provider {
    case "codex": "site-openai"
    case "claude": "site-claude"
    case "grok": "site-grok"
    case "copilot": "site-copilot"
    case "gemini": "site-gemini"
    case "perplexity": "site-perplexity"
    default: nil
    }
  }

  static func title(_ provider: String) -> String {
    switch provider {
    case "codex": "Codex"
    case "claude": "Claude"
    case "grok": "Grok"
    case "copilot": "GitHub Copilot"
    case "gemini": "Gemini"
    case "perplexity": "Perplexity"
    default: provider
    }
  }
}
