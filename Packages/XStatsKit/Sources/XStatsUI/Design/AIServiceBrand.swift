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
    case "workbuddy", "workbuddy-ai": NSColor(srgbRed: 0, green: 0.78, blue: 0.52, alpha: 1)
    default: foreground
    }
  }

  static func menuBarTitle(_ provider: String) -> String {
    title(provider)
  }

  static func logoName(_ provider: String) -> String? {
    switch provider {
    case "codex", "openai": "site-openai"
    case "claude", "anthropic": "site-claude"
    case "grok": "site-grok"
    case "copilot": "site-copilot"
    case "gemini": "site-gemini"
    case "perplexity": "site-perplexity"
    case "workbuddy", "workbuddy-ai": "site-workbuddy"
    case "codebuddy", "codebuddy-cn": "tool-codebuddy"
    case "cursor": "site-cursor"
    case "windsurf": "site-windsurf"
    case "kiro": "site-kiro-color"
    case "antigravity": "site-antigravity-color"
    case "qoder", "qoder-cn": "site-qoder-color"
    case "trae", "trae-cn": "site-trae-color"
    case "zhipu": "site-zhipu-color"
    case "zai": "site-zai"
    case "kimi", "kimi-code", "kimi-code-cn", "moonshot", "moonshot-cn": "site-kimi-color"
    case "minimax", "minimax-cn": "site-minimax-color"
    case "deepseek": "site-deepseek-color"
    case "doubao": "site-doubao-color"
    case "qwen", "qwen-cn", "qwen-token-plan": "site-qwen-color"
    case "bailian-token-plan": "site-bailian-color"
    case "stepfun", "stepfun-cn": "site-stepfun-color"
    case "opencode-go", "opencode-zen": "site-opencode"
    case "openrouter": "site-openrouter-color"
    default: nil
    }
  }

  /// 彩色资源保留原色；单色资源交给当前外观着色，避免深色背景下消失。
  static func usesOriginalLogoColors(_ provider: String) -> Bool {
    guard let name = logoName(provider) else { return false }
    return name.hasSuffix("-color")
      || ["site-claude", "site-gemini", "tool-codebuddy"].contains(name)
  }

  static func title(_ provider: String) -> String {
    switch provider {
    case "codex": "Codex"
    case "claude": "Claude"
    case "grok": "Grok"
    case "copilot": "GitHub Copilot"
    case "gemini": "Gemini"
    case "perplexity": "Perplexity"
    case "workbuddy": "WorkBuddy"
    case "workbuddy-ai": "WorkBuddy AI"
    case "openai": "OpenAI"
    case "anthropic": "Anthropic"
    case "codebuddy": "CodeBuddy"
    case "codebuddy-cn": "CodeBuddy CN"
    case "cursor": "Cursor"
    case "windsurf": "Windsurf"
    case "kiro": "Kiro"
    case "antigravity": "Antigravity"
    case "qoder": "Qoder"
    case "qoder-cn": "Qoder CN"
    case "trae": "Trae"
    case "trae-cn": "Trae CN"
    case "zhipu": "Zhipu GLM"
    case "zai": "Z.ai"
    case "kimi", "moonshot": "Kimi"
    case "moonshot-cn": "Kimi CN"
    case "kimi-code": "Kimi Code"
    case "kimi-code-cn": "Kimi Code CN"
    case "minimax": "MiniMax"
    case "minimax-cn": "MiniMax CN"
    case "deepseek": "DeepSeek"
    case "doubao": "Doubao"
    case "qwen": "Qwen"
    case "qwen-cn": "Qwen CN"
    case "qwen-token-plan": "Qwen Token Plan"
    case "bailian-token-plan": "Bailian Token Plan"
    case "stepfun": "StepFun"
    case "stepfun-cn": "StepFun CN"
    case "opencode-go": "OpenCode Go"
    case "opencode-zen": "OpenCode Zen"
    case "openrouter": "OpenRouter"
    default: provider
    }
  }
}
