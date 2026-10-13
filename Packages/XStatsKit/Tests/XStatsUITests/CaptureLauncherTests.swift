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
        #expect(!CaptureAppLauncher.isCaptureApplication(root))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "work.12306.xstats.capture"], format: .xml, options: 0).write(to: info)
        #expect(CaptureAppLauncher.isCaptureApplication(root))
        #expect(!CaptureAppLauncher.isCaptureApplication(root.deletingLastPathComponent()))
    }
}
