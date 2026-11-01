// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Metrics
import Testing
@testable import XStatsUI

@MainActor
struct AIServiceBrandTests {
  @Test(arguments: [
    "open.spotify.com", "kali.download", "nodejs.org", "www.sony.com", "www.amazon.com",
    "www.okx.com",
  ])
  func addedSiteLogosRenderVisiblePixels(host: String) throws {
    let target = try #require(EgressTarget.sites.first { $0.host == host })
    let name = try #require(target.logo)
    let image = try #require(LogoCache.shared.image(named: name, template: false))
    #expect(!image.isTemplate)
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = try #require(NSAppearance(named: appearanceName))
      let bitmap = try #require(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0))
      let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
      appearance.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill(using: .copy)
        image.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
        NSGraphicsContext.restoreGraphicsState()
      }
      let visiblePixels = (0..<24).reduce(0) { count, y in
        count + (0..<24).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
      }
      #expect(visiblePixels > 5, "\(host): \(appearanceName)")
    }
  }

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
