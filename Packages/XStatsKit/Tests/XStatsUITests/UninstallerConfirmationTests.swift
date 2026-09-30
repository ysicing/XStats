// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@testable import Cleaner
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct UninstallerConfirmationTests {
    private func app(_ name: String) -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name,
                     bundleIdentifier: "test.\(name)", version: nil, teamIdentifier: nil)
    }

    @Test func cancelKeepsSelectedAppWithoutRemovingIt() async throws {
        let controller = UninstallerController(currentBundleIdentifier: nil, findLeftovers: {
            [AppLeftover(url: $0.url, kind: .application, size: 100)]
        })
        let target = app("ConfirmationTestA")
        controller.select(target)
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.isScanning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.canUninstall)

        controller.requestUninstall()
        #expect(controller.pendingUninstall == target)
        controller.cancelUninstall()
        controller.confirmUninstall()

        #expect(controller.pendingUninstall == nil)
        #expect(controller.selected == target)
        #expect(!controller.isRemoving)
    }

    @Test func switchingAppInvalidatesOldConfirmation() async throws {
        let controller = UninstallerController(currentBundleIdentifier: nil, findLeftovers: {
            [AppLeftover(url: $0.url, kind: .application, size: 100)]
        })
        let first = app("ConfirmationTestA")
        let second = app("ConfirmationTestB")
        controller.select(first)
        let deadline = ContinuousClock.now + .seconds(30)
        while controller.isScanning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.canUninstall)
        controller.requestUninstall()
        controller.select(second)
        controller.confirmUninstall()

        #expect(controller.pendingUninstall == nil)
        #expect(controller.selected == second)
        #expect(!controller.isRemoving)
    }
}
