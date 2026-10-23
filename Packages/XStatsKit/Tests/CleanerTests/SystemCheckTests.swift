// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct SystemCheckTests {
  @Test func launchAgentAuditDistinguishesMissingProgramsFromUnknownTargets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Library/LaunchAgents")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, program) in [
      ("missing", root.appendingPathComponent("missing/bin").path),
      ("path", "python3"),
      ("external", "/Volumes/NotMountedFixture/bin"),
    ] {
      try PropertyListSerialization.data(
        fromPropertyList: ["Label": "fixture." + name, "Program": program],
        format: .xml, options: 0
      ).write(to: directory.appendingPathComponent(name + ".plist"))
    }
    try Data("invalid".utf8).write(to: directory.appendingPathComponent("broken.plist"))
    let result = SystemCheck.launchAgents(home: root.path)
    #expect(result.status == .attention)
    #expect(result.isComplete == false)
    #expect(result.evidence.contains { $0.contains("fixture.missing") })
    #expect(result.evidence.contains { $0.contains("fixture.path") } == false)
    #expect(result.evidence.contains { $0.contains("fixture.external") } == false)
    #expect(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing.plist").path)
    )
  }

  @Test func previewRulesRemainReadOnlyAndDoNotContainExecutionPlans() {
    let rules = PreviewRuleCatalog.rules
    #expect(rules.isEmpty == false)
    #expect(rules.allSatisfy { $0.previewOnly && !$0.selectedByDefault && !$0.usesToolCleaner })
  }

  @Test func preferenceAuditPreservesUnknownAndFalseValues() {
    let normal = SystemCheck.legacyOverrides(values: [
      "NSAppSleepDisabled": .bool(false),
      "skip-verify": .bool(false),
      "skip-verify-locked": .bool(false),
      "skip-verify-remote": .bool(false),
    ])
    #expect(normal.status == .normal)
    #expect(normal.isComplete)
    let overridden = SystemCheck.legacyOverrides(values: ["NSAppSleepDisabled": .bool(true)])
    #expect(overridden.status == .attention)
    let unknown = SystemCheck.legacyOverrides(values: ["NSAppSleepDisabled": .unknown])
    #expect(unknown.isComplete == false)
  }

  @Test func preferenceFilesAreBoundedAndSymlinksAreNotRead() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Library/Preferences")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(SystemCheck.legacyOverrides(home: root.path).status == .normal)
    let target = root.appendingPathComponent("target.plist")
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["NSAppSleepDisabled": true], format: .binary, options: 0)
    try data.write(to: target)
    let preference = directory.appendingPathComponent(".GlobalPreferences.plist")
    try FileManager.default.createSymbolicLink(at: preference, withDestinationURL: target)
    #expect(SystemCheck.legacyOverrides(home: root.path).isComplete == false)
    #expect(try Data(contentsOf: target) == data)
    try FileManager.default.removeItem(at: preference)
    try Data(repeating: 32, count: 1_048_577).write(to: preference)
    #expect(SystemCheck.legacyOverrides(home: root.path).isComplete == false)
  }

  @Test func findingsBoundLocallyDisplayedEvidence() {
    let result = SystemCheckFinding(
      id: "fixture", title: "", status: .optional, detail: "",
      evidence: Array(repeating: String(repeating: "x", count: 1_000), count: 50))
    #expect(result.evidence.count == 20)
    #expect(result.evidence.allSatisfy { $0.count == 500 })
  }
}
