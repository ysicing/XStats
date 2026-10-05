// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
@testable import AudioControl

struct AudioVolumeBalanceTests {
    @Test func perChannelWritesKeepTheExistingBalance() {
        let levels = AudioHardwareClient.balancedVolumes([0.4, 0.8], level: 0.3)
        #expect(levels.count == 2)
        #expect(abs(levels[0] - 0.2) < 1e-6 && abs(levels[1] - 0.4) < 1e-6, "左右比例保持 1:2，平均值等于目标 0.3")
    }

    @Test func scaledChannelsAreClampedToTheValidRange() {
        #expect(AudioHardwareClient.balancedVolumes([0.2, 0.6], level: 0.9) == [0.45, 1])
    }

    @Test func singleMissingOrSilentChannelsFallBackToTheTargetLevel() {
        #expect(AudioHardwareClient.balancedVolumes([0.7], level: 0.5) == [0.5], "单个元素（主音量或单声道）直接写目标值")
        #expect(AudioHardwareClient.balancedVolumes([0.4, nil], level: 0.5) == [0.5, 0.5], "读数不完整时不能猜测比例")
        #expect(AudioHardwareClient.balancedVolumes([0, 0], level: 0.5) == [0.5, 0.5], "全部为 0 时无比例可保留")
    }
}
