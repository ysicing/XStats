// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct ApplicationManagementTests {
    @Test func thinAndFatMachOArchitecturesAreBounded() {
        #expect(ApplicationMetadata.architecture(in: Data([0xcf, 0xfa, 0xed, 0xfe, 12, 0, 0, 1])) == .appleSilicon)
        #expect(ApplicationMetadata.architecture(in: Data([0xfe, 0xed, 0xfa, 0xcf, 1, 0, 0, 7])) == .intel)
        var fat = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2])
        fat.append(contentsOf: [1, 0, 0, 12] + Array(repeating: 0, count: 16))
        fat.append(contentsOf: [1, 0, 0, 7] + Array(repeating: 0, count: 16))
        #expect(ApplicationMetadata.architecture(in: fat) == .universal)
        #expect(ApplicationMetadata.architecture(in: fat.prefix(20)) == .unknown)
        #expect(ApplicationMetadata.architecture(in: Data([0xca, 0xfe, 0xba, 0xbe, 255, 255, 255, 255])) == .unknown)
        #expect(ApplicationMetadata.architecture(in: Data("not executable".utf8)) == .unknown)
    }

    @Test func packageIdentityUsesFullTapAndInstalledVersions() throws {
        let output = #"""
        Warning: local index
        {"formulae":[{"name":"tool","full_name":"vendor/tap/tool","installed":[{"version":"1.0"},{"version":"1.1"}],"versions":{"stable":"2.0"},"revision":1,"outdated":true,"pinned":false}],"casks":[{"full_token":"vendor/apps/editor","name":["Editor"],"installed":"3.0","version":"4.0","outdated":true,"artifacts":[{"app":["Editor.app"],"target":"/Users/demo/Applications/Editor.app"}]}]}
        """#
        let packages = try HomebrewManagement.parse(output, prefix: URL(fileURLWithPath: "/opt/homebrew"))
        let formula = try #require(packages.first { $0.kind == .formula })
        #expect(formula.name == "vendor/tap/tool")
        #expect(formula.latestVersion == "2.0_1")
        #expect(formula.installedVersions == ["1.0", "1.1"])
        #expect(formula.installationURLs.map(\.path) == ["/opt/homebrew/Cellar/tool/1.0", "/opt/homebrew/Cellar/tool/1.1"])
        #expect(try HomebrewManagement.arguments(for: .uninstall, package: formula) == ["uninstall", "--formula", "vendor/tap/tool"])
        let cask = try #require(packages.first { $0.kind == .cask })
        #expect(cask.applicationURLs.map(\.path) == ["/Users/demo/Applications/Editor.app"])
        #expect(try HomebrewManagement.arguments(for: .upgrade, package: cask) == ["upgrade", "--cask", "vendor/apps/editor"])
    }

    @Test func dangerousTokensAndTruncatedJSONAreRejected() {
        for token in ["--help", "../tool", "vendor//tool", "tool;rm", "tool\nother"] {
            let object: [String: Any] = ["formulae": [], "casks": [["full_token": token, "installed": "1"]]]
            let data = try! JSONSerialization.data(withJSONObject: object)
            #expect(throws: HomebrewManagement.InventoryError.self) {
                try HomebrewManagement.parse(String(decoding: data, as: UTF8.self), prefix: URL(fileURLWithPath: "/opt/homebrew"))
            }
        }
        #expect(throws: (any Error).self) { try HomebrewManagement.parse("{\"formulae\":[]", prefix: URL(fileURLWithPath: "/opt/homebrew")) }
    }

    @Test func pinnedPackagesCannotBeUpgradedAndUninstallNeverForces() throws {
        let pinned = HomebrewPackage(name: "tool", displayName: "tool", kind: .formula, installedVersions: ["1"], latestVersion: "2",
            outdated: true, pinned: true, installationURLs: [], applicationURLs: [])
        #expect(throws: HomebrewManagement.InventoryError.self) { try HomebrewManagement.arguments(for: .upgrade, package: pinned) }
        #expect(try HomebrewManagement.arguments(for: .uninstall, package: pinned) == ["uninstall", "--formula", "tool"])
    }
}
