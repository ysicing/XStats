// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// 订阅页面与菜单栏共用服务名称和标志；未知服务保留原名并使用通用图标。
enum AIServiceBrand {
  static let defaultMenuBarProviders = ["codex", "claude", "gemini", "grok"]
  static let menuBarOrder = defaultMenuBarProviders + ["copilot", "perplexity"]

  /// 三合一的小圆点沿用服务标志的主色；黑白标志随菜单栏明暗适配。
  static func dotColor(_ provider: String, foreground: NSColor) -> NSColor {
    switch provider {
    case "claude": NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    case "gemini": NSColor(srgbRed: 0.31, green: 0.53, blue: 0.93, alpha: 1)
    case "copilot": NSColor(srgbRed: 0.53, green: 0.40, blue: 0.87, alpha: 1)
    case "perplexity": NSColor(srgbRed: 0.14, green: 0.60, blue: 0.61, alpha: 1)
    default: foreground
    }
  }

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
