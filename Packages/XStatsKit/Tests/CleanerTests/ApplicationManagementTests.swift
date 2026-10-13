// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct ApplicationManagementTests {
    @Test func packageMetadataUsesHomebrewReceiptsAndPreservesUnknownValues() throws {
        let output = #"""
        {"formulae":[
          {"name":"tool","full_name":"tool","desc":" Development tool ","installed":[{"version":"1","time":1780000000,"installed_on_request":false},{"version":"2","time":1790000000,"installed_on_request":true}]},
          {"name":"library","full_name":"library","installed":[{"version":"1","installed_on_request":false}]},
          {"name":"legacy","full_name":"legacy","installed":[{"version":"1","installed_on_request":false},{"version":"2"}]}
        ],"casks":[{"full_token":"editor","name":["Editor"],"desc":"Native editor","installed":"3","installed_time":1791000000}]}
        """#
        let packages = try HomebrewManagement.parse(output, prefix: URL(fileURLWithPath: "/opt/homebrew"))
        let tool = try #require(packages.first { $0.name == "tool" })
        #expect(tool.installReason == .requested)
        #expect(tool.installedAt == Date(timeIntervalSince1970: 1790000000))
        #expect(tool.summary == "Development tool")
        let library = try #require(packages.first { $0.name == "library" })
        #expect(library.installReason == .dependency && library.installedAt == nil && library.summary == nil)
        #expect(packages.first { $0.name == "legacy" }?.installReason == .unknown)
        let editor = try #require(packages.first { $0.kind == .cask })
        #expect(editor.installedAt == Date(timeIntervalSince1970: 1791000000))
        #expect(editor.summary == "Native editor" && editor.installReason == .unknown)
    }

    @Test func invalidOptionalMetadataDoesNotDiscardAnInstalledPackage() throws {
        for invalid: Any in [true, false, -1, 0, 253_402_300_800.0, "1790000000", NSNull()] {
            let object: [String: Any] = [
                "formulae": [["name": "tool", "full_name": "tool", "desc": 42,
                    "installed": [["version": "1", "time": invalid, "installed_on_request": 1]]]],
                "casks": [["full_token": "editor", "installed": "1", "desc": NSNull(), "installed_time": invalid]],
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            let packages = try HomebrewManagement.parse(String(decoding: data, as: UTF8.self), prefix: URL(fileURLWithPath: "/opt/homebrew"))
            #expect(packages.count == 2)
            #expect(packages.allSatisfy { $0.installedAt == nil && $0.summary == nil && $0.installReason == .unknown })
        }
        let object: [String: Any] = ["formulae": [["name": "tool", "full_name": "tool",
            "desc": String(repeating: "x", count: 10_000), "installed": [["version": "1"]]]], "casks": []]
        let data = try JSONSerialization.data(withJSONObject: object)
        let package = try #require(HomebrewManagement.parse(String(decoding: data, as: UTF8.self), prefix: URL(fileURLWithPath: "/opt/homebrew")).first)
        #expect(package.summary?.count == 2_048)
    }

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
        // brew info --json=v2 在产物外层提供解析后的安装路径，保留自定义 appdir。
        let output = #"""
        {"formulae":[{"name":"tool","full_name":"vendor/tap/tool","installed":[{"version":"1.0"},{"version":"1.1"}],"versions":{"stable":"2.0"},"revision":1,"outdated":true,"pinned":false}],"casks":[{"full_token":"vendor/apps/editor","name":["Editor"],"installed":"3.0","version":"4.0","outdated":true,"artifacts":[{"app":["Editor.app",{"target":"Renamed.app"}],"target":"/Users/demo/Applications/Renamed.app"}]}]}
        """#
        let packages = try HomebrewManagement.parse(output, prefix: URL(fileURLWithPath: "/opt/homebrew"))
        let formula = try #require(packages.first { $0.kind == .formula })
        #expect(formula.name == "vendor/tap/tool")
        #expect(formula.latestVersion == "2.0_1")
        #expect(formula.installedVersions == ["1.0", "1.1"])
        #expect(formula.installationURLs.map(\.path) == ["/opt/homebrew/Cellar/tool/1.0", "/opt/homebrew/Cellar/tool/1.1"])
        #expect(try HomebrewManagement.arguments(for: .uninstall, package: formula) == ["uninstall", "--formula", "vendor/tap/tool"])
        let cask = try #require(packages.first { $0.kind == .cask })
        #expect(cask.applicationURLs.map(\.path) == ["/Users/demo/Applications/Renamed.app"])
        #expect(try HomebrewManagement.arguments(for: .upgrade, package: cask) == ["upgrade", "--cask", "vendor/apps/editor"])
    }

    @Test func caskResolvedTargetWithoutRenameIsPreserved() throws {
        let output = #"{"formulae":[],"casks":[{"full_token":"editor","installed":"1","artifacts":[{"app":["Editor.app"],"target":"/Users/demo/Applications/Editor.app"}]}]}"#
        let package = try #require(HomebrewManagement.parse(output, prefix: URL(fileURLWithPath: "/opt/homebrew")).first)
        #expect(package.applicationURLs.map(\.path) == ["/Users/demo/Applications/Editor.app"])
        #expect(package.installationURLs == package.applicationURLs)
    }

    @Test func caskTargetsFollowHomebrewPathRules() {
        let home = "/Users/demo"
        #expect(HomebrewManagement.applicationURL(["Foo.app", ["target": "Bar.app"]], home: home)?.path == "/Applications/Bar.app")
        #expect(HomebrewManagement.applicationURL(["Foo.app", ["target": "Tools/Bar.app"]], home: home)?.path == "/Applications/Tools/Bar.app")
        #expect(HomebrewManagement.applicationURL(["Foo.app", ["target": "~/Applications/Bar.app"]], home: home)?.path == "/Users/demo/Applications/Bar.app")
        #expect(HomebrewManagement.applicationURL(["Foo.app", ["target": "/Opt/Bar.app"]], home: home)?.path == "/Opt/Bar.app")
        #expect(HomebrewManagement.applicationURL(["Nested/Foo.app"], home: home)?.path == "/Applications/Foo.app")
        // 相对 target 不能跳出 /Applications；非 .app 目标不视为应用。
        #expect(HomebrewManagement.applicationURL(["Foo.app", ["target": "../Bar.app"]], home: home) == nil)
        #expect(HomebrewManagement.applicationURL(["Foo.app", ["target": "Bar"]], home: home) == nil)
    }

    @Test func malformedPackagesAreSkippedWithoutDroppingTheInventory() throws {
        let object: [String: Any] = [
            "formulae": [["name": "tool", "full_name": "tool", "installed": [["version": "1"]]],
                         ["name": "broken", "full_name": "broken", "installed": NSNull()], "not an object"],
            "casks": [["full_token": "viewer", "installed": "2", "artifacts": [["app": ["Viewer.app"]]]],
                      ["full_token": "viewer", "installed": "3"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let packages = try HomebrewManagement.parse(String(decoding: data, as: UTF8.self), prefix: URL(fileURLWithPath: "/opt/homebrew"))
        #expect(packages.map(\.id) == ["formula:tool", "cask:viewer"])
        #expect(packages.last?.applicationURLs.map(\.path) == ["/Applications/Viewer.app"])
    }

    @Test func unrecognizedCaskRejectsTheInventorySoItsAppIsNotUninstalledDirectly() throws {
        for cask: Any in [["full_token": "editor", "installed": NSNull(), "artifacts": [["app": ["Editor.app"]]]],
                          ["full_token": "--help", "installed": "1"], "not an object"] {
            let object: [String: Any] = ["formulae": [], "casks": [cask, ["full_token": "viewer", "installed": "2"]]]
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: HomebrewManagement.InventoryError.self) {
                try HomebrewManagement.parse(String(decoding: data, as: UTF8.self), prefix: URL(fileURLWithPath: "/opt/homebrew"))
            }
        }
    }

    @Test func dangerousTokensAreSkippedAndInvalidStructureIsRejected() throws {
        for token in ["--help", "../tool", "vendor//tool", "tool;rm", "tool\nother"] {
            let object: [String: Any] = ["formulae": [["name": token, "full_name": token, "installed": [["version": "1"]]]], "casks": []]
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(try HomebrewManagement.parse(String(decoding: data, as: UTF8.self), prefix: URL(fileURLWithPath: "/opt/homebrew")).isEmpty)
        }
        #expect(throws: (any Error).self) { try HomebrewManagement.parse("{\"formulae\":[]", prefix: URL(fileURLWithPath: "/opt/homebrew")) }
        #expect(throws: HomebrewManagement.InventoryError.self) {
            try HomebrewManagement.parse(#"{"formulae":[]}"#, prefix: URL(fileURLWithPath: "/opt/homebrew"))
        }
        // 清单只解析 stdout，前置的诊断文本说明输出被污染，整体拒绝。
        #expect(throws: (any Error).self) {
            try HomebrewManagement.parse("Warning: x\n{\"formulae\":[],\"casks\":[]}", prefix: URL(fileURLWithPath: "/opt/homebrew"))
        }
    }

    @Test func pinnedPackagesCannotBeUpgradedAndUninstallNeverForces() throws {
        let pinned = HomebrewPackage(name: "tool", displayName: "tool", kind: .formula, installedVersions: ["1"], latestVersion: "2",
            outdated: true, pinned: true, installationURLs: [], applicationURLs: [])
        #expect(throws: HomebrewManagement.InventoryError.self) { try HomebrewManagement.arguments(for: .upgrade, package: pinned) }
        #expect(try HomebrewManagement.arguments(for: .uninstall, package: pinned) == ["uninstall", "--formula", "tool"])
    }
}
