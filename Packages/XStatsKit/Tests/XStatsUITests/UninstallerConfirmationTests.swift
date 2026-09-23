// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct UninstallerConfirmationTests {
    private func app(_ name: String) -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name,
                     bundleIdentifier: "test.\(name)", version: nil, teamIdentifier: nil)
    }

    @Test func cancelKeepsSelectedAppWithoutRemovingIt() {
        let controller = UninstallerController()
        let target = app("ConfirmationTestA")
        controller.select(target)

        controller.requestUninstall()
        #expect(controller.pendingUninstall == target)
        controller.cancelUninstall()
        controller.confirmUninstall()

        #expect(controller.pendingUninstall == nil)
        #expect(controller.selected == target)
        #expect(!controller.isRemoving)
    }

    @Test func switchingAppInvalidatesOldConfirmation() {
        let controller = UninstallerController()
        let first = app("ConfirmationTestA")
        let second = app("ConfirmationTestB")
        controller.select(first)
        controller.requestUninstall()
        controller.select(second)
        controller.confirmUninstall()

        #expect(controller.pendingUninstall == nil)
        #expect(controller.selected == second)
        #expect(!controller.isRemoving)
    }
}
