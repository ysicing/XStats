// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Metrics

struct SleepAssertionTests {
    @Test(arguments: ["NetworkClientActive", "InternalPreventDisplaySleep"])
    func includesNetworkAndInternalDisplayRequests(type: String) throws {
        let reading = try #require(SleepAssertionReader.parse(pid: 1, name: "service", path: "/usr/libexec/powerd",
                                                            bundlePath: nil, assertions: [
            ["AssertType": type, "AssertLevel": kIOPMAssertionLevelOn, "AssertName": "request"]
        ]))
        #expect(reading.isSystemService)
        #expect(reading.preventsSystemSleep == (type == "NetworkClientActive"))
        #expect(reading.preventsDisplaySleep == (type == "InternalPreventDisplaySleep"))
    }

    @Test func ignoresInactiveAndUserActivityButCombinesSleepTypes() throws {
        let assertions: [[String: Any]] = [
            ["AssertType": "UserIsActive", "AssertLevel": kIOPMAssertionLevelOn, "AssertName": "touch"],
            ["AssertType": "PreventSystemSleep", "AssertLevel": kIOPMAssertionLevelOff, "AssertName": "inactive"],
            ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": kIOPMAssertionLevelOn, "AssertName": "audio"],
            ["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": kIOPMAssertionLevelOn, "AssertName": "display", "HumanReadableReason": "Watching video"],
            ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": kIOPMAssertionLevelOn, "AssertName": "audio"]
        ]
        let reading = try #require(SleepAssertionReader.parse(pid: 12, name: "Player", path: "/Applications/Player.app/Contents/MacOS/Player",
                                                            bundlePath: "/Applications/Player.app", assertions: assertions))
        #expect(reading.preventsDisplaySleep && reading.preventsSystemSleep)
        #expect(!reading.isSystemService && reading.reason == "audio · Watching video")
        #expect(SleepAssertionReader.parse(pid: 1, name: "inactive", path: nil, bundlePath: nil,
                                          assertions: Array(assertions.prefix(2))) == nil)
    }

    @Test func foldsOnlySystemDaemonsAndBoundsReasons() throws {
        let assertions: [[String: Any]] = [["AssertType": "PreventSystemSleep", "AssertLevel": kIOPMAssertionLevelOn,
                                           "AssertName": String(repeating: "x", count: 1_000)]]
        for (path, bundle, service) in [("/usr/libexec/powerd", nil, true), ("/usr/bin/caffeinate", nil, false),
                                       ("/System/Applications/Music.app/Contents/MacOS/Music", "/System/Applications/Music.app", false)] {
            let reading = try #require(SleepAssertionReader.parse(pid: 1, name: "test", path: path,
                                                                bundlePath: bundle, assertions: assertions))
            #expect(reading.isSystemService == service && reading.reason.count == 256)
        }
    }

    @Test func nativeReaderReturnsUniqueProcesses() throws {
        var assertion: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "XStats sleep assertion test" as CFString, &assertion)
        #expect(status == kIOReturnSuccess)
        defer { IOPMAssertionRelease(assertion) }
        let processes = try SleepAssertionReader.read()
        #expect(processes.contains { $0.id == ProcessInfo.processInfo.processIdentifier
            && $0.preventsSystemSleep && $0.reason.contains("XStats sleep assertion test") })
        #expect(Set(processes.map(\.id)).count == processes.count)
        #expect(processes.allSatisfy { $0.preventsDisplaySleep || $0.preventsSystemSleep })
    }
}
