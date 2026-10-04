// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct DisplayHardwareReadTests {
    /// 显式运行才探测本机硬件，只发 Get VCP；不执行 Set VCP，也不保存显示器标识或序列号。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XSTATS_DDC_READ_REPORT"] != nil))
    func readOnlyCapabilityProbe() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["XSTATS_DDC_READ_REPORT"])
        let displays = DisplayInfo.all().filter { !$0.isBuiltIn }
        #expect(!displays.isEmpty)
        let backend = NativeDisplayDDC()
        var report: [[String: Any]] = []
        for display in displays {
            let readings = await backend.read(display.target, cancellation: DDCCancellation())
            var controls: [String: Any] = [:]
            for control in DisplayControl.allCases {
                switch readings[control] {
                case .value(let value):
                    #expect(value.maximum > 0 && value.current <= value.maximum)
                    controls[String(describing: control)] = ["supported": true, "current": value.current, "maximum": value.maximum]
                default: controls[String(describing: control)] = ["status": String(describing: readings[control])]
                }
            }
            report.append(["display": display.name, "controls": controls, "readOnly": true])
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
