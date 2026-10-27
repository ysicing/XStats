// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import XStatsUI

@MainActor
struct AIServiceBrandTests {
  @Test(arguments: [
    "codex", "claude", "gemini", "grok", "copilot", "perplexity", "workbuddy", "workbuddy-ai",
    "openai", "anthropic", "codebuddy", "codebuddy-cn", "cursor", "windsurf", "kiro",
    "antigravity", "qoder", "qoder-cn", "trae", "trae-cn", "zhipu", "zai",
    "kimi", "kimi-code", "kimi-code-cn", "moonshot", "moonshot-cn", "minimax", "minimax-cn",
    "deepseek", "doubao", "qwen", "qwen-cn", "qwen-token-plan", "bailian-token-plan",
    "stepfun", "stepfun-cn", "opencode-go", "opencode-zen", "openrouter",
  ])
  func bundledServiceLogosDecodeInBothRenderingModes(provider: String) throws {
    let name = try #require(AIServiceBrand.logoName(provider))
    let original = try #require(LogoCache.shared.image(named: name, template: false))
    let template = try #require(LogoCache.shared.image(named: name, template: true))
    #expect(original.isValid && template.isValid)
    #expect(original.size.width > 0 && original.size.height > 0)
    #expect(!original.isTemplate && template.isTemplate)
    #expect(original !== template)
  }

  @Test func unknownServicesKeepTheirIdentity() {
    for provider in ["private-cursor-proxy", "claude-custom", "future-service"] {
      #expect(AIServiceBrand.logoName(provider) == nil)
      #expect(AIServiceBrand.title(provider) == provider)
      #expect(!AIServiceBrand.usesOriginalLogoColors(provider))
    }
  }
}
