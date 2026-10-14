// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
@testable import XStatsUI

@Suite struct CaptureLauncherTests {
    @Test func onlyMatchingApplicationIdentityIsAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = root.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "other.application"], format: .xml, options: 0).write(to: info)
        #expect(!CaptureAppLauncher.isCaptureApplication(root, trust: .adHocDevelopment))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "work.12306.xstats.capture"], format: .xml, options: 0).write(to: info)
        #expect(!CaptureAppLauncher.isCaptureApplication(root, trust: .adHocDevelopment), "伪造 plist 的未签名包不能启动")
        #expect(!CaptureAppLauncher.isCaptureApplication(root.deletingLastPathComponent(), trust: .adHocDevelopment))
    }

    @Test func validDevelopmentSignatureDoesNotSatisfyProductionTrust() throws {
        let app = try signedFixture()
        defer { try? FileManager.default.removeItem(at: app) }
        #expect(CaptureAppLauncher.isCaptureApplication(app, trust: .adHocDevelopment))
        #expect(!CaptureAppLauncher.isCaptureApplication(app, trust: .team("ABCDE12345")))
        #expect(!CaptureAppLauncher.isCaptureApplication(app, trust: .team("")))
        #expect(!CaptureAppLauncher.isCaptureApplication(app, trust: .unavailable))
    }

    @Test func tamperedResourcesInvalidateAnOtherwiseMatchingApplication() throws {
        let app = try signedFixture()
        defer { try? FileManager.default.removeItem(at: app) }
        let resource = app.appendingPathComponent("Contents/Resources/fixture.txt")
        try Data("tampered".utf8).write(to: resource)
        #expect(!CaptureAppLauncher.isCaptureApplication(app, trust: .adHocDevelopment))
    }

    @Test func signedIdentityCannotBeReplacedByAMatchingPlist() throws {
        let app = try signedFixture(identifier: "other.application")
        defer { try? FileManager.default.removeItem(at: app) }
        #expect(!CaptureAppLauncher.isCaptureApplication(app, trust: .adHocDevelopment))
    }

    private func signedFixture(identifier: String = "work.12306.xstats.capture") throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        do {
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "work.12306.xstats.capture", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Fixture"))
            try Data("original".utf8).write(to: contents.appendingPathComponent("Resources/fixture.txt"))
            let signing = Process()
            signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signing.arguments = ["--force", "--sign", "-", "--identifier", identifier, app.path]
            signing.standardOutput = FileHandle.nullDevice; signing.standardError = FileHandle.nullDevice
            try signing.run(); signing.waitUntilExit()
            try #require(signing.terminationStatus == 0)
            return app
        } catch {
            try? FileManager.default.removeItem(at: app)
            throw error
        }
    }
}
