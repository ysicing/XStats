// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct SystemCheckTests {
  @Test func previewRulesRemainReadOnlyAndDoNotContainExecutionPlans() {
    let rules = PreviewRuleCatalog.rules
    #expect(rules.isEmpty == false)
    #expect(rules.allSatisfy { $0.previewOnly && !$0.selectedByDefault && !$0.usesToolCleaner })
  }

  @Test func findingsBoundLocallyDisplayedEvidence() {
    let result = SystemCheckFinding(
      id: "fixture", title: "", status: .optional, detail: "",
      evidence: Array(repeating: String(repeating: "x", count: 1_000), count: 50))
    #expect(result.evidence.count == 20)
    #expect(result.evidence.allSatisfy { $0.count == 500 })
  }

  @Test(arguments: [0, 20, 26])
  func homebrewPreviewMarksTruncatedLists(_ count: Int) async throws {
    let lines = (0..<count).map { "dependency-\($0)" }
    let environment = CleanEnvironment(
      runningBundleIdentifiers: { [] }, isToolAvailable: { $0 == "brew" },
      runTool: { tool, arguments in
        #expect(tool == "brew")
        #expect(arguments == ["autoremove", "--dry-run"])
        return ToolRunResult(status: 0, output: lines.joined(separator: "\n"))
      })
    let finding = try await SystemCheck.homebrew(environment: environment)
    #expect(finding.status == .optional)
    #expect(finding.isComplete == (count <= 20))
    #expect(finding.evidence == Array(lines.prefix(20)))
  }

  @Test(arguments: [500, 501])
  func homebrewPreviewMarksTruncatedLines(_ length: Int) async throws {
    let output = String(repeating: "x", count: length)
    let environment = CleanEnvironment(
      runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
      runTool: { _, _ in ToolRunResult(status: 0, output: output) })
    let finding = try await SystemCheck.homebrew(environment: environment)
    #expect(finding.status == .optional)
    #expect(finding.isComplete == (length <= 500))
    #expect(finding.evidence == [String(output.prefix(500))])
  }
}
