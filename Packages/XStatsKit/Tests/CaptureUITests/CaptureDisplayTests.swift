// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import CoreGraphics
@testable import CaptureUI

@Suite @MainActor struct CaptureDisplayTests {
    @Test func windowCaptureIgnoresDisconnectionOfItsOriginalDisplay() {
        #expect(!CaptureController.shouldInterruptForDisplayChange(displayID: 1, windowID: 42, availableDisplays: [2]))
        #expect(!CaptureController.shouldInterruptForDisplayChange(displayID: 1, windowID: 42, availableDisplays: []))
    }
    @Test func regionAndDisplayCaptureStopOnlyWhenTheirDisplayDisappears() {
        #expect(!CaptureController.shouldInterruptForDisplayChange(displayID: 1, windowID: nil, availableDisplays: [1, 2]))
        #expect(CaptureController.shouldInterruptForDisplayChange(displayID: 1, windowID: nil, availableDisplays: [2]))
        #expect(CaptureController.shouldInterruptForDisplayChange(displayID: 1, windowID: nil, availableDisplays: []))
    }
}
