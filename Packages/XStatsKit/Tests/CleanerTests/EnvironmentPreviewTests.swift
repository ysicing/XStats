// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct EnvironmentPreviewTests {
  @Test func dnsRequiresAnAnswerForTheQueriedName() {
    #expect(EnvironmentPreview.dnsAnswers(";; connection timed out").isEmpty)
    #expect(EnvironmentPreview.dnsAnswers("apple.com. 60 IN A 999.1.2.3").isEmpty)
    #expect(EnvironmentPreview.dnsAnswers("apple.com. 60 IN A 1.2.3.+4").isEmpty)
    #expect(EnvironmentPreview.dnsAnswers("apple.com. 60 IN A 1..2.3.4").isEmpty)
    #expect(EnvironmentPreview.dnsAnswers("apple.com. unknown IN A 1.2.3.4").isEmpty)
    #expect(EnvironmentPreview.dnsAnswers("other.com. 60 IN A 1.2.3.4").isEmpty)
    #expect(EnvironmentPreview.dnsAnswers("apple.com. 60 IN A 1.2.3.4") == ["1.2.3.4"])
  }

  @Test func oneMalformedRouteCannotMakeTheRouteCheckComplete() async throws {
    let environment = CleanEnvironment(
      runningBundleIdentifiers: { [] },
      runTool: { tool, arguments in
        if tool == "route" {
          return ToolRunResult(
            status: 0, output: arguments.contains("-inet6") ? "interface: \n" : "interface: en0")
        }
        return ToolRunResult(status: 0, output: "apple.com. 60 IN A 1.2.3.4")
      })
    let findings = try await EnvironmentPreview.network(environment: environment)
    let routes = try #require(findings.first)
    #expect(routes.evidence == ["interface: en0"])
    #expect(!routes.isComplete)
    #expect(findings.last?.status == .normal)
  }

  @Test func unsuccessfulProbesCannotReportHealthyNetwork() async throws {
    let environment = CleanEnvironment(
      runningBundleIdentifiers: { [] },
      runTool: { tool, _ in
        ToolRunResult(status: tool == "route" ? 0 : 1, output: "unrecognized output")
      })
    let findings = try await EnvironmentPreview.network(environment: environment)
    #expect(findings.allSatisfy { $0.status == .unchecked && !$0.isComplete })
    let images = try await EnvironmentPreview.images(environment: environment)
    #expect(images.status == .unchecked)
    #expect(!images.isComplete)
  }

  @Test func cancellationStopsBeforeStartingDNSProbe() async throws {
    let gate = ProbeGate()
    let environment = CleanEnvironment(
      runningBundleIdentifiers: { [] },
      runTool: { tool, _ in
        await gate.record(tool)
        try await Task.sleep(for: .seconds(30))
        return ToolRunResult(status: 0, output: "")
      })
    let task = Task { try await EnvironmentPreview.network(environment: environment) }
    await gate.waitForStart()
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {
      #expect(await gate.tools == ["route"])
    }
  }

  @Test func imagePreviewSeparatesUserImagesFromSystemRuntimes() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "images": [
          [
            "image-path": "/Users/fixture/Downloads/installer.dmg",
            "system-entities": [["mount-point": "/Volumes/Installer"]],
          ],
          [
            "image-path": "/Library/Developer/CoreSimulator/Images/runtime.dmg",
            "system-entities": [["mount-point": "/Volumes/Runtime"]],
          ],
          ["image-path": "/Users/fixture/malformed.dmg"],
        ]
      ], format: .xml, options: 0)
    let finding = try EnvironmentPreview.imageFinding(data)
    #expect(finding.status == .optional)
    #expect(!finding.isComplete)
    #expect(finding.evidence == ["/Users/fixture/Downloads/installer.dmg → /Volumes/Installer"])
    #expect(throws: (any Error).self) {
      try EnvironmentPreview.imageFinding(Data("truncated".utf8))
    }
  }

  private actor ProbeGate {
    var tools: [String] = []
    var start: CheckedContinuation<Void, Never>?

    func record(_ tool: String) {
      tools.append(tool)
      start?.resume()
      start = nil
    }

    func waitForStart() async {
      if !tools.isEmpty { return }
      await withCheckedContinuation { start = $0 }
    }
  }
}
