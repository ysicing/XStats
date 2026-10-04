// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import AudioControl

/// 只读 HAL 集成测试；不请求捕获权限，不修改实际音量、静音或设备路由。
struct AudioHardwareReadTests {
    @Test func readsBoundedDeviceDataAndReleasesListenersAfterRepeatedVisibilityChanges() async {
        let client = AudioHardwareClient()
        let snapshot = await client.snapshot(includeApplications: false)
        #expect(snapshot.applications.isEmpty)
        #expect(Set(snapshot.devices.map(\.id)).count == snapshot.devices.count)
        #expect(snapshot.devices.allSatisfy { !($0.uid.hasPrefix("XStats.Audio.")) })
        for device in snapshot.devices {
            for level in [device.inputVolume, device.outputVolume].compactMap({ $0 }) {
                #expect(level.isFinite && (0...1).contains(level))
            }
        }
        for _ in 0..<10 {
            client.watch(applications: false) {}
            #expect(await client.listenerCount() > 0)
            client.stopWatching()
            #expect(await client.listenerCount() == 0)
        }
    }
}
