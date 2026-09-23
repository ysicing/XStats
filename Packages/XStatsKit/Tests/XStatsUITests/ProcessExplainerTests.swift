// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Testing
@testable import XStatsUI
#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite struct ProcessExplainerTests {
    @MainActor @Test func unavailableAppleModelStopsWithoutGeneratingAnExplanation() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *),
              case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability else { return }
        let explainer = ProcessExplainer()
        explainer.explain(.init(pid: 0, name: "Example", displayName: "Example",
                                executablePath: nil, appBundlePath: nil,
                                cpu: nil, memory: nil, networkRate: nil))
        for _ in 0..<100 where explainer.phase == .running {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(explainer.phase == .failed(tr("Apple 智能本机模型当前不可用。")))
        #expect(explainer.text.isEmpty)
        #endif
    }

    @Test func localProcessFactsIncludeExecutablePath() {
        let subject = ProcessExplainer.Subject(pid: 0, name: "Example", displayName: "Example",
            executablePath: "/Users/sample/Example", appBundlePath: nil,
            cpu: nil, memory: nil, networkRate: nil)
        #expect(ProcessExplainer.facts(for: subject).contains("/Users/sample/Example"))
    }
}
