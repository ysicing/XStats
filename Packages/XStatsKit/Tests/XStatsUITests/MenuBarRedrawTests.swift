// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import XStatsUI

@MainActor
struct MenuBarRedrawTests {
    @Test func unrelatedSamplesDoNotInvalidateSlowChangingItems() {
        let previous = MenuBarReading.sample
        var next = previous
        next.cpu = 0.9
        next.cpuHistory.append(0.9)
        next.download = 900_000
        #expect(next.hasSameImage(as: previous, item: .disk, style: .ring))
        #expect(next.hasSameImage(as: previous, item: .battery, style: .icon))
        #expect(next.hasSameImage(as: previous, item: .aiUsage, style: .inline))
        #expect(!next.hasSameImage(as: previous, item: .cpu, style: .ring))
        #expect(!next.hasSameImage(as: previous, item: .network, style: .inline))
    }

    @Test func historyRefreshesEvenWhenLatestValueIsUnchanged() {
        let previous = MenuBarReading.sample
        var next = previous
        next.cpuHistory[0] = 0.99
        #expect(next.hasSameImage(as: previous, item: .cpu, style: .ring))
        #expect(!next.hasSameImage(as: previous, item: .cpu, style: .history))
        #expect(!next.hasSameImage(as: previous, item: .cpu, style: .line))
    }

    @Test func statusIndicatorsInvalidateUnchangedValues() {
        let previous = MenuBarReading.sample
        var next = previous
        next.batteryCharging = true
        #expect(!next.hasSameImage(as: previous, item: .battery, style: .icon))
        next = previous
        next.bluetoothDevice = ("keyboard", 15)
        #expect(!next.hasSameImage(as: previous, item: .battery, style: .ring))
        next = previous
        next.keepAwake = true
        #expect(!next.hasSameImage(as: previous, item: .disk, style: .ring))
    }
}
