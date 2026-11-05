// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct HomebrewImpactPreviewTests {
  private let package = HomebrewPackage(
    name: "vendor/tap/tool", displayName: "tool", kind: .formula,
    installedVersions: ["1"], latestVersion: "2", outdated: true, pinned: false,
    installationURLs: [], applicationURLs: [])

  @Test func upgradeUsesOnlyNativeDryRunAndPreservesTheWholePlan() async throws {
    let preview = try await HomebrewManagement.preview(
      .upgrade, package: package, inventory: [package]
    ) { arguments in
      #expect(arguments == ["upgrade", "--dry-run", "--formula", "vendor/tap/tool"])
      return "Would upgrade tool 1 -> 2\nWould install dependency: library\n"
    }
    #expect(preview.canProceed)
    #expect(preview.output.contains("Would install dependency: library"))
    #expect(preview.package == package && preview.action == .upgrade)
  }

  @Test func uninstallChecksInstalledDependentsWithoutInvokingUninstall() async throws {
    let preview = try await HomebrewManagement.preview(
      .uninstall, package: package, inventory: [package]
    ) { arguments in
      #expect(arguments == ["uses", "--installed", "--recursive", "vendor/tap/tool"])
      return "vendor/apps/editor viewer\nviewer\n"
    }
    #expect(preview.dependents == ["vendor/apps/editor", "viewer"])
    #expect(!preview.canProceed)
    let clear = try await HomebrewManagement.preview(
      .uninstall, package: package, inventory: [package]
    ) { _ in "" }
    #expect(clear.canProceed && clear.dependents.isEmpty)
  }

  @Test func failedUnknownAndStalePreviewsNeverBecomeAnEmptySuccess() async throws {
    await #expect(throws: HomebrewManagement.InventoryError.self) {
      try await HomebrewManagement.preview(.upgrade, package: package, inventory: []) { _ in
        Issue.record("A stale target must not invoke brew")
        return "plan"
      }
    }
    await #expect(throws: HomebrewManagement.InventoryError.self) {
      try await HomebrewManagement.preview(.upgrade, package: package, inventory: [package]) { _ in
        "  \n"
      }
    }
    await #expect(throws: URLError.self) {
      try await HomebrewManagement.preview(.uninstall, package: package, inventory: [package]) {
        _ in
        throw URLError(.cannotParseResponse)
      }
    }
    #expect(throws: HomebrewManagement.InventoryError.self) {
      try HomebrewManagement.parseDependents("Warning: unknown response")
    }
  }

  @Test func caskDependentsAreTransitiveTapAwareAndCycleSafe() throws {
    let packages = try inventory(
      #"""
      [{"full_token":"vendor/apps/base","installed":"1","depends_on":null},
       {"full_token":"vendor/apps/editor","installed":"1","depends_on":{"cask":["vendor/apps/base","viewer"]}},
       {"full_token":"viewer","installed":"1","depends_on":{"cask":["vendor/apps/editor"]}},
       {"full_token":"other/apps/base","installed":"1","depends_on":null}]
      """#)
    let base = try #require(packages.first { $0.name == "vendor/apps/base" })
    #expect(
      try HomebrewManagement.caskDependents(of: base, in: packages) == [
        "vendor/apps/editor", "viewer",
      ])
    let other = try #require(packages.first { $0.name == "other/apps/base" })
    #expect(try HomebrewManagement.caskDependents(of: other, in: packages).isEmpty)
  }

  @Test func damagedOrAmbiguousCaskDependenciesBlockThePreview() throws {
    for casks in [
      #"[{"full_token":"base","installed":"1","depends_on":null},{"full_token":"editor","installed":"1","depends_on":{"cask":42}}]"#,
      #"[{"full_token":"a/apps/base","installed":"1","depends_on":null},{"full_token":"b/apps/base","installed":"1","depends_on":null},{"full_token":"editor","installed":"1","depends_on":{"cask":["base"]}}]"#,
      #"[{"full_token":"base","installed":"1"}]"#,
    ] {
      let packages = try inventory(casks)
      let base = try #require(packages.first)
      #expect(throws: HomebrewManagement.InventoryError.self) {
        try HomebrewManagement.caskDependents(of: base, in: packages)
      }
    }
  }

  @Test(arguments: [
    ("new-base", "old-base", "old-base"),
    ("vendor/apps/new-base", "old-base", "vendor/apps/old-base"),
    ("vendor/apps/new-base", "legacy/apps/old-base", "legacy/apps/old-base"),
    ("vendor/apps/new-base", "old-base", "old-base"),
  ])
  func renamedCaskDependenciesBlockUninstall(
    name: String, oldToken: String, dependency: String
  ) async throws {
    let packages = try inventory(
      #"""
      [{"full_token":"\#(name)","old_tokens":["\#(oldToken)"],"installed":"1","depends_on":null},
       {"full_token":"editor","old_tokens":["old-editor"],"installed":"1","depends_on":{"cask":["\#(dependency)"]}},
       {"full_token":"viewer","installed":"1","depends_on":{"cask":["old-editor"]}},
       {"full_token":"other/apps/old-base","installed":"1","depends_on":null}]
      """#)
    let base = try #require(packages.first { $0.name == name })
    if dependency == "old-base" {
      await #expect(throws: HomebrewManagement.InventoryError.self) {
        try await HomebrewManagement.preview(.uninstall, package: base, inventory: packages) { _ in
          ""
        }
      }
    } else {
      let preview = try await HomebrewManagement.preview(
        .uninstall, package: base, inventory: packages
      ) { _ in "" }
      #expect(preview.dependents == ["editor", "viewer"])
      #expect(!preview.canProceed)
    }
  }

  @Test func renamedCoreCaskDependenciesBlockUninstall() async throws {
    let packages = try inventory(
      #"""
      [{"full_token":"new-base","old_tokens":["old-base"],"installed":"1","depends_on":null},
       {"full_token":"editor","installed":"1","depends_on":{"cask":["old-base"]}}]
      """#)
    let base = try #require(packages.first { $0.name == "new-base" })
    let preview = try await HomebrewManagement.preview(
      .uninstall, package: base, inventory: packages
    ) { _ in "" }
    #expect(preview.dependents == ["editor"])
    #expect(!preview.canProceed)
  }

  @Test(arguments: ["42", #"["--invalid"]"#, #"[""]"#, "null"])
  func malformedCaskRenamesBlockThePreview(_ oldTokens: String) throws {
    let packages = try inventory(
      #"[{"full_token":"base","old_tokens":\#(oldTokens),"installed":"1","depends_on":null}]"#)
    let base = try #require(packages.first)
    #expect(throws: HomebrewManagement.InventoryError.self) {
      try HomebrewManagement.caskDependents(of: base, in: packages)
    }
  }

  @Test func unrelatedUnmatchedOrAmbiguousCaskEdgesDoNotBlockThePreview() throws {
    let packages = try inventory(
      #"""
      [{"full_token":"base","installed":"1","depends_on":null},
       {"full_token":"editor","installed":"1","depends_on":{"cask":["base"]}},
       {"full_token":"stray","installed":"1","depends_on":{"cask":["unknown-or-renamed"]}},
       {"full_token":"a/apps/lib","installed":"1","depends_on":null},
       {"full_token":"b/apps/lib","installed":"1","depends_on":null},
       {"full_token":"user","installed":"1","depends_on":{"cask":["lib"]}}]
      """#)
    let base = try #require(packages.first { $0.name == "base" })
    #expect(try HomebrewManagement.caskDependents(of: base, in: packages) == ["editor"])
  }

  @Test func caskUninstallDoesNotSendACaskTokenToFormulaUses() async throws {
    let packages = try inventory(
      #"[{"full_token":"vendor/apps/editor","installed":"1","depends_on":null}]"#)
    let cask = try #require(packages.first)
    let preview = try await HomebrewManagement.preview(
      .uninstall, package: cask, inventory: packages
    ) { _ in
      Issue.record("Cask reverse dependencies come from the installed inventory")
      return ""
    }
    #expect(preview.canProceed)
  }

  private func inventory(_ casks: String) throws -> [HomebrewPackage] {
    try HomebrewManagement.parse(
      #"{"formulae":[],"casks":"# + casks + "}",
      prefix: URL(fileURLWithPath: "/opt/homebrew"))
  }
}
